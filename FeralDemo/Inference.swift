import CoreML
import CoreVideo
import Foundation

/// Wraps FeralModel.mlpackage. The mlpackage was exported with softmax + take
/// class-1 baked into the graph, so the output is already in [0, 1].
final class Inference: @unchecked Sendable {
    private let model: MLModel
    private let inferenceQueue = DispatchQueue(label: "feraldemo.inference", qos: .userInitiated)

    init() throws {
        guard let url = Bundle.main.url(forResource: "FeralModel", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "FeralModel", withExtension: "mlpackage") else {
            throw NSError(domain: "FeralDemo.Inference", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "FeralModel.mlpackage missing from app bundle"])
        }
        let isPrecompiled = url.pathExtension == "mlmodelc"
        print("[Inference] loading \(url.lastPathComponent) (precompiled=\(isPrecompiled))")

        let config = MLModelConfiguration()
        // At 256² (8,192-token self-attention), ANE compile fails AND the CPU
        // fallback OOMs trying to materialize the 8192² attention matrix.
        // .cpuAndGPU skips ANE entirely — Metal SDPA tiles internally so it
        // doesn't need the full matrix.
        config.computeUnits = .cpuAndGPU

        let loadStart = Date()
        self.model = try MLModel(contentsOf: url, configuration: config)
        let loadMs = Date().timeIntervalSince(loadStart) * 1000
        print(String(format: "[Inference] model loaded in %.0f ms", loadMs))

        if #available(iOS 17.4, *) {
            Task.detached(priority: .utility) {
                await Self.logComputePlan(url: url, configuration: config)
            }
        }
    }

    /// Run inference on 64 captured frames. Heavy work runs off the main thread.
    func run(buffers: [CVPixelBuffer]) async throws -> [Float] {
        let model = self.model
        return try await withCheckedThrowingContinuation { cont in
            inferenceQueue.async {
                do {
                    let prepStart = Date()
                    let input = try Preprocess.buildModelInput(from: buffers)
                    let provider = try MLDictionaryFeatureProvider(dictionary: ["frames": input])
                    let prepMs = Date().timeIntervalSince(prepStart) * 1000

                    let predStart = Date()
                    let prediction = try model.prediction(from: provider)
                    let predMs = Date().timeIntervalSince(predStart) * 1000

                    guard let scoresArray = prediction.featureValue(for: "scores")?.multiArrayValue else {
                        throw NSError(domain: "FeralDemo.Inference", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Output 'scores' not found"])
                    }
                    let scores = Self.unpack(scoresArray)
                    let s = Self.scoreStats(scores)
                    print(String(
                        format: "[Inference] prep=%.0fms predict=%.0fms scores n=%d min=%.3f mean=%.3f max=%.3f nans=%d",
                        prepMs, predMs, scores.count, s.min, s.mean, s.max, s.nans
                    ))
                    cont.resume(returning: scores)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
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

    /// Walks the compiled program and prints which compute device CoreML
    /// chose for each op. The summary tells us whether the re-export actually
    /// reached the ANE; the off-ANE breakdown shows which op types are still
    /// blocking the model from running entirely on the Neural Engine.
    @available(iOS 17.4, *)
    private static func logComputePlan(url: URL, configuration: MLModelConfiguration) async {
        do {
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            guard case .program(let program) = plan.modelStructure else {
                print("[Inference] MLComputePlan: not an mlprogram, skipping device map")
                return
            }

            var ane = 0, gpu = 0, cpu = 0, unknown = 0
            var perOp: [String: (ane: Int, gpu: Int, cpu: Int)] = [:]

            func walk(_ block: MLModelStructure.Program.Block) {
                for op in block.operations {
                    let device = plan.deviceUsage(for: op)?.preferred
                    var bucket = perOp[op.operatorName, default: (0, 0, 0)]
                    switch device {
                    case .cpu:           cpu += 1;     bucket.cpu += 1
                    case .gpu:           gpu += 1;     bucket.gpu += 1
                    case .neuralEngine:  ane += 1;     bucket.ane += 1
                    case .none:          unknown += 1
                    @unknown default:    unknown += 1
                    }
                    perOp[op.operatorName] = bucket
                    for nested in op.blocks { walk(nested) }
                }
            }
            for (_, function) in program.functions { walk(function.block) }

            let total = ane + gpu + cpu + unknown
            print("[Inference] MLComputePlan: \(total) ops — ANE=\(ane), GPU=\(gpu), CPU=\(cpu), unknown=\(unknown)")

            // Op types with any work landing off the ANE — the candidates to
            // attack next if we're not yet 100% on Neural Engine.
            let offAne = perOp
                .filter { $0.value.gpu + $0.value.cpu > 0 }
                .sorted { ($0.value.gpu + $0.value.cpu) > ($1.value.gpu + $1.value.cpu) }
            if offAne.isEmpty {
                print("[Inference] every op is on the Neural Engine")
            } else {
                print("[Inference] off-ANE op types (top 15):")
                for (name, c) in offAne.prefix(15) {
                    print("  '\(name)': ANE=\(c.ane) GPU=\(c.gpu) CPU=\(c.cpu)")
                }
            }
        } catch {
            print("[Inference] MLComputePlan load failed: \(error.localizedDescription)")
        }
    }
}
