import CoreVideo
import Foundation
import Observation

/// Holds the rolling list of captured frames and schedules inference chunks.
///
/// Inference uses 64-frame chunks with a 32-frame shift (50% overlap), so each
/// frame in the middle of the recording gets scored twice and we average. The
/// first 32 frames and the last <chunk in flight> are scored only once.
///
/// Policy:
///   - One inference at a time. Process is fast enough (~570 ms / chunk) to
///     keep up at 32-frame intervals on a 24 fps camera (1333 ms).
///   - When a chunk finishes, immediately try to kick the next chunk
///     (start += 32). If the camera hasn't caught up yet, the kick fires
///     later when `append(buffer:)` adds the trailing frame.
///   - Per-frame `score` exposed by `Frame` is `scoreSum / scoreCount` —
///     callers (the bar, the saved session) treat it as a single value.
///
/// To keep memory bounded, each frame's CVPixelBuffer is dropped once both
/// (a) it sits below the next pending chunk's start, and (b) it's older than
/// the latest 128 captured frames.
@MainActor
@Observable
final class FrameBuffer {
    struct Frame: Identifiable {
        let index: Int
        var pixelBuffer: CVPixelBuffer?
        var scoreSum: Float = 0
        var scoreCount: Int = 0

        var id: Int { index }
        var score: Float? {
            scoreCount > 0 ? scoreSum / Float(scoreCount) : nil
        }
    }

    static let chunkSize: Int = 64
    static let chunkShift: Int = 32

    private(set) var frames: [Frame] = []
    private(set) var inferenceInflight: Bool = false
    private var nextChunkStart: Int = 0
    private var inflightStart: Int = -1

    private let inference: Inference?
    private let onError: (Error) -> Void

    init(inference: Inference?, onError: @escaping (Error) -> Void) {
        self.inference = inference
        self.onError = onError
    }

    func append(buffer: CVPixelBuffer) {
        frames.append(Frame(index: frames.count, pixelBuffer: buffer))
        dropOldBuffers()
        kickInferenceIfReady()
    }

    /// Simulator fallback: append a frame with no pixel buffer (no real inference).
    func appendSynthetic(score: Float? = nil) {
        var frame = Frame(index: frames.count, pixelBuffer: nil)
        if let score {
            frame.scoreSum = score
            frame.scoreCount = 1
        }
        frames.append(frame)
    }

    /// Simulator hook — applies a chunk of synthetic scores through the same
    /// running-average path the real inference path uses, so the saved session
    /// in simulator looks the same shape (frames in [chunkShift, last) end up
    /// with `scoreCount == 2`).
    func applySyntheticChunk(_ scores: [Float], start: Int) {
        applyChunkScores(scores, start: start)
    }

    func reset() {
        frames.removeAll()
        inferenceInflight = false
        nextChunkStart = 0
        inflightStart = -1
    }

    private func dropOldBuffers() {
        let total = frames.count
        let keepLatestFrom = max(0, total - 128)
        // Frames at or after `pendingLow` may still be needed to feed the
        // in-flight chunk and/or the next-pending chunk.
        let pendingLow = inferenceInflight ? min(inflightStart, nextChunkStart) : nextChunkStart

        for i in 0..<keepLatestFrom where frames[i].pixelBuffer != nil {
            if i < pendingLow {
                frames[i].pixelBuffer = nil
            }
        }
    }

    private func kickInferenceIfReady() {
        guard !inferenceInflight, let inference else { return }
        let total = frames.count
        let chunkSize = Self.chunkSize

        let start = nextChunkStart
        let end = start + chunkSize - 1
        guard end < total else { return }

        let buffers = frames[start...end].compactMap { $0.pixelBuffer }
        guard buffers.count == chunkSize else { return }

        inferenceInflight = true
        inflightStart = start
        nextChunkStart = start + Self.chunkShift

        Task.detached { [weak self] in
            do {
                let scores = try await inference.run(buffers: buffers)
                await MainActor.run {
                    self?.applyChunkScores(scores, start: start)
                    self?.finishInflight()
                }
            } catch {
                await MainActor.run {
                    self?.handleInferenceError(error)
                }
            }
        }
    }

    /// Adds a chunk's scores into the running per-frame average.
    private func applyChunkScores(_ scores: [Float], start: Int) {
        for (offset, score) in scores.enumerated() {
            let i = start + offset
            if i < frames.count {
                frames[i].scoreSum += score
                frames[i].scoreCount += 1
            }
        }
    }

    private func finishInflight() {
        inferenceInflight = false
        inflightStart = -1
        dropOldBuffers()
        kickInferenceIfReady()
    }

    private func handleInferenceError(_ error: Error) {
        inferenceInflight = false
        inflightStart = -1
        onError(error)
    }
}
