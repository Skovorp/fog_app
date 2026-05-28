import CoreML
import CoreVideo
import Foundation

/// Wraps one of the FERAL Core ML packages. Two output shapes are handled:
///
///   - **Per-frame (FoG)** — output `scores`, shape (1, 64). One probability
///     per captured frame in [0, 1]. Clamped (filters NaN / overflow) and
///     returned as-is.
///   - **Chunk-level regression (walking / chair / tapping)** — output
///     `updrs_score`, shape (1,). A single denormalized scalar (the head's
///     `mean + std * z`) for the whole chunk. Clamped into the evaluation's
///     `clampRange` (chair → [0, 1], walking / tapping → [0, 3]) and then
///     **normalized by `clampRange.upperBound`** so every head produces
///     per-frame scores in [0, 1] regardless of the underlying raw scale.
///     The normalized value is stamped to all 64 capture frames so the
///     score bar and saved Session stay homogeneous.
///
/// The rest of the pipeline (FrameBuffer, FrameBarView, Session, results
/// screen, PDF) assumes scores ∈ [0, 1] uniformly — no per-evaluation
/// branching needed downstream.
final class Inference: @unchecked Sendable {
    let evaluation: Evaluation
    private let model: MLModel
    private let outputName: String
    private let inferenceQueue = DispatchQueue(label: "luche.inference", qos: .userInitiated)

    init(for evaluation: Evaluation) throws {
        self.evaluation = evaluation
        let resource = evaluation.modelResourceName
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: resource, withExtension: "mlpackage") else {
            throw NSError(domain: "Luche.Inference", code: 1,
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

    /// Run inference on `captureFramesPerChunk` raw camera frames. Returns
    /// one score in [0, 1] per capture frame, regardless of which underlying
    /// model is loaded — see `normalizeForCaptureFrames` for the per-head
    /// clamp + normalize.
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
                        throw NSError(domain: "Luche.Inference", code: 2,
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

    /// Clamp raw model output into the evaluation's `clampRange`, then
    /// **normalize into [0, 1]** by dividing by the range's upper bound, and
    /// finally shape into one score per capture frame:
    ///
    ///   - **FoG**: model emits 64 per-frame probabilities. clampRange =
    ///     [0, 1] → divide by 1 is a no-op; the clamp itself just filters
    ///     NaN / overflow noise.
    ///   - **Regression heads**: model emits one denormalized scalar.
    ///     Chair clampRange = [0, 1] (no-op divide); walking / tapping
    ///     clampRange = [0, 3] (divide by 3 → [0, 1] fraction-of-seen-
    ///     severity). The normalized scalar is stamped onto all 64 frames
    ///     of the chunk.
    ///
    /// Every downstream consumer can assume `score ∈ [0, 1]` uniformly.
    private static func normalizeForCaptureFrames(_ raw: [Float], evaluation: Evaluation) -> [Float] {
        let lo = evaluation.clampRange.lowerBound
        let hi = evaluation.clampRange.upperBound
        // `.leastNonzeroMagnitude` is ambiguous between Float / Double /
        // Duration here, so spell out the type or the compiler binds it
        // to Duration and fails.
        let span = Swift.max(hi - lo, Float.leastNonzeroMagnitude)
        let normalize: (Float) -> Float = {
            let clamped = Swift.max(lo, Swift.min(hi, $0))
            return (clamped - lo) / span
        }
        if evaluation.outputIsPerFrame {
            return raw.map(normalize)
        }
        let scalar = raw.first ?? .nan
        let value = normalize(scalar)
        return Array(repeating: value, count: evaluation.captureFramesPerChunk)
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
