import CoreVideo
import Foundation
import Observation

/// Holds the rolling list of captured frames and schedules inference chunks.
///
/// Chunk strategy is per-evaluation, configured from `Inference.evaluation`:
///   - **FoG**: 64-frame chunks with a 32-frame shift (50% overlap). Each
///     middle frame ends up with two predictions; we average. First 32 and
///     trailing in-flight frames are scored only once.
///   - **Walking / Chair / Tapping**: 64-frame chunks with a 64-frame shift
///     (no overlap). The model returns a single chunk-level scalar which
///     `Inference` stamps to every capture frame in the window — so each
///     frame here ends up with scoreCount=1.
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

    /// Capture-side chunk size. Always 64 — matches the rolling 2.67 s window
    /// the camera buffers across all evaluations.
    static let chunkSize: Int = 64
    /// Default shift, used by simulator-only synthetic streams and as the
    /// chunkShift when no Inference is attached (loading-spinner case).
    static let chunkShift: Int = 32

    /// Per-instance chunk shift — driven by the evaluation. 32 for FoG (50%
    /// overlap), 64 for the regression heads (no overlap).
    let chunkShift: Int

    private(set) var frames: [Frame] = []
    private(set) var inferenceInflight: Bool = false
    private var nextChunkStart: Int = 0
    private var inflightStart: Int = -1

    private let inference: Inference?
    private let onError: (Error) -> Void

    init(inference: Inference?, onError: @escaping (Error) -> Void) {
        self.inference = inference
        self.chunkShift = inference?.evaluation.captureChunkShift ?? Self.chunkShift
        self.onError = onError
    }

    func append(buffer: CVPixelBuffer) {
        frames.append(Frame(index: frames.count, pixelBuffer: buffer))
        dropOldBuffers()
        kickInferenceIfReady()
    }

    /// Simulator fallback: append a frame with no pixel buffer.
    func appendSynthetic(score: Float? = nil) {
        var frame = Frame(index: frames.count, pixelBuffer: nil)
        if let score {
            frame.scoreSum = score
            frame.scoreCount = 1
        }
        frames.append(frame)
    }

    /// Simulator hook — applies a chunk of synthetic scores through the same
    /// running-average path the real inference path uses.
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

        // Skip-queued: when inference can't keep up with capture, skip past
        // older fully-captured chunks and jump to the latest one. The frames
        // in skipped chunks stay scoreless — those gaps show up as holes in
        // the timeline. Only enabled for the slow 64-frame walking debug
        // evaluation; everyone else processes chunks in order.
        if inference.evaluation.skipQueuedChunks {
            while nextChunkStart + chunkShift + chunkSize - 1 < total {
                nextChunkStart += chunkShift
            }
        }

        let start = nextChunkStart
        let end = start + chunkSize - 1
        guard end < total else { return }

        let buffers = frames[start...end].compactMap { $0.pixelBuffer }
        guard buffers.count == chunkSize else { return }

        inferenceInflight = true
        inflightStart = start
        nextChunkStart = start + chunkShift

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

    /// Adds a chunk's scores into the running per-frame average. Inference
    /// always returns exactly `chunkSize` scores (FoG: per-frame; regression:
    /// chunk scalar stamped to every frame).
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
