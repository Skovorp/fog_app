import CoreML
import CoreVideo
import Foundation

/// Wraps one of the FERAL Core ML packages. Two output shapes are handled:
///
///   - **Per-frame (FoG)** — output `scores`, shape (1, 64). One probability
///     per captured frame in [0, 1]. Returned as-is.
///   - **Chunk-level regression (walking / chair / tapping)** — output
///     `updrs_score`, shape (1,). A single denormalized UPDRS score in [0, 4]
///     for the whole chunk. We map it back to a per-frame [0, 1] score by
///     dividing by 4, clamping, and stamping the result to all 64 capture
///     frames in the chunk so the score bar and saved Session stay homogeneous.
///
/// Both contracts produce a `[Float]` of length `evaluation.captureFramesPerChunk`
/// to the caller so the rest of the pipeline (FrameBuffer, FrameBarView,
/// Session) doesn't need to know which kind of model was run.
final class Inference: @unchecked Sendable {
    let evaluation: Evaluation
    private let model: MLModel
    private let outputName: String
    private let inferenceQueue = DispatchQueue(label: "feraldemo.inference", qos: .userInitiated)

    init(for evaluation: Evaluation) throws {
        self.evaluation = evaluation
        let resource = evaluation.modelResourceName
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: resource, withExtension: "mlpackage") else {
            throw NSError(domain: "FeralDemo.Inference", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(resource).mlpackage missing from app bundle"])
        }
        let isPrecompiled = url.pathExtension == "mlmodelc"
        print("[Inference] loading \(url.lastPathComponent) for \(evaluation.displayName) (precompiled=\(isPrecompiled))")

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU

        let loadStart = Date()
        self.model = try MLModel(contentsOf: url, configuration: config)
        let loadMs = Date().timeIntervalSince(loadStart) * 1000
        print(String(format: "[Inference] model loaded in %.0f ms", loadMs))

        self.outputName = evaluation.outputIsPerFrame ? "scores" : "updrs_score"

        if #available(iOS 17.4, *) {
            Task.detached(priority: .utility) {
                await Self.logComputePlan(url: url, configuration: config)
            }
        }
    }

    /// Run inference on `captureFramesPerChunk` raw camera frames. Returns one
    /// score in [0, 1] per capture frame regardless of which underlying model
    /// is loaded.
    func run(buffers: [CVPixelBuffer]) async throws -> [Float] {
        precondition(buffers.count == evaluation.captureFramesPerChunk,
                     "Expected \(evaluation.captureFramesPerChunk) frames, got \(buffers.count)")
        let model = self.model
        let evaluation = self.evaluation
        let outputName = self.outputName
        return try await withCheckedThrowingContinuation { cont in
            inferenceQueue.async {
                do {
                    let prepStart = Date()
                    let input = try Preprocess.buildModelInput(from: buffers, for: evaluation)
                    let provider = try MLDictionaryFeatureProvider(dictionary: ["frames": input])
                    let prepMs = Date().timeIntervalSince(prepStart) * 1000

                    let predStart = Date()
                    let prediction = try model.prediction(from: provider)
                    let predMs = Date().timeIntervalSince(predStart) * 1000

                    guard let array = prediction.featureValue(for: outputName)?.multiArrayValue else {
                        throw NSError(domain: "FeralDemo.Inference", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Output '\(outputName)' not found"])
                    }
                    let raw = Self.unpack(array)
                    let stamped = Self.normalizeForCaptureFrames(raw, evaluation: evaluation)
                    let s = Self.scoreStats(stamped)
                    print(String(
                        format: "[Inference] %@ prep=%.0fms predict=%.0fms raw=%@ stamped n=%d min=%.3f mean=%.3f max=%.3f nans=%d",
                        evaluation.displayName, prepMs, predMs, raw.map { String(format: "%.3f", $0) }.joined(separator: ","),
                        stamped.count, s.min, s.mean, s.max, s.nans
                    ))
                    cont.resume(returning: stamped)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// FoG returns one [0,1] probability per capture frame — keep as-is.
    /// Regression returns a "severity" scalar — clamp to [0, 1] and stamp it
    /// to every capture frame in the chunk. The regression heads are loosely
    /// MDS-UPDRS-adjacent but were trained on small/narrow datasets, so we
    /// don't claim the output is on the official 0-4 UPDRS scale. Treat the
    /// number as a 0-1 trouble-with-task probability instead.
    private static func normalizeForCaptureFrames(_ raw: [Float], evaluation: Evaluation) -> [Float] {
        if evaluation.outputIsPerFrame {
            return raw
        }
        let scalar = raw.first ?? .nan
        let clamped = Swift.max(0, Swift.min(1, scalar))
        return Array(repeating: clamped, count: evaluation.captureFramesPerChunk)
    }

    private static func unpack(_ arr: MLMultiArray) -> [Float] {
        let n = arr.count
        var out = [Float](repeating: 0, count: n)
        let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: n)
        for i in 0..<n {
            out[i] = ptr[i]
        }
        return out
    }

    private static func scoreStats(_ scores: [Float]) -> (min: Float, max: Float, mean: Float, nans: Int) {
        var lo = Float.infinity
        var hi = -Float.infinity
        var sum: Double = 0
        var nans = 0
        for s in scores {
            if s.isNaN { nans += 1; continue }
            lo = Swift.min(lo, s)
            hi = Swift.max(hi, s)
            sum += Double(s)
        }
        let valid = scores.count - nans
        if valid == 0 { return (.nan, .nan, .nan, nans) }
        return (lo, hi, Float(sum / Double(valid)), nans)
    }

    @available(iOS 17.4, *)
    private static func logComputePlan(url: URL, configuration: MLModelConfiguration) async {
        do {
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            guard case .program(let program) = plan.modelStructure else {
                print("[Inference] MLComputePlan: not an mlprogram, skipping device map")
                return
            }
            var ane = 0, gpu = 0, cpu = 0, unknown = 0
            func walk(_ block: MLModelStructure.Program.Block) {
                for op in block.operations {
                    let device = plan.deviceUsage(for: op)?.preferred
                    switch device {
                    case .cpu:           cpu += 1
                    case .gpu:           gpu += 1
                    case .neuralEngine:  ane += 1
                    case .none:          unknown += 1
                    @unknown default:    unknown += 1
                    }
                    for nested in op.blocks { walk(nested) }
                }
            }
            for (_, function) in program.functions { walk(function.block) }
            let total = ane + gpu + cpu + unknown
            print("[Inference] MLComputePlan: \(total) ops — ANE=\(ane), GPU=\(gpu), CPU=\(cpu), unknown=\(unknown)")
        } catch {
            print("[Inference] MLComputePlan load failed: \(error.localizedDescription)")
        }
    }
}
