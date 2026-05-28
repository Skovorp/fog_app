import CoreVideo
import Foundation
import Observation

/// Holds the rolling list of captured frames and schedules inference chunks.
///
/// **Chunk strategy (identical for every evaluation):**
///   - 64-frame chunks aligned to capture-index 0 (chunk *k* = `[64k, 64k+64)`).
///   - **Non-overlapping** — `captureChunkShift == 64`. Every captured frame
///     belongs to exactly one chunk and ends up with `scoreCount == 1` after
///     either the live scheduler scores it or the post-session drain fills
///     it in.
///   - **Skip-to-latest + stash.** Single in-flight inference. When the
///     worker frees up:
///       - If ≥2 full chunks are ready, score the *latest* one live and
///         push every older ready chunk onto `stash`.
///       - Stashed chunks' `CVPixelBuffer`s are dropped immediately — the
///         session's `.mp4` (written by `CameraSession.videoWriter` in real
///         time) is the source of truth for re-decoding them in the
///         post-session `PostProcessor` drain.
///
/// Memory in steady state: only the in-flight chunk's 64 pixel buffers stay
/// in RAM. `frames` itself grows linearly with capture but each `Frame` is
/// tiny once its pixelBuffer is nilled (just the int index + score sum/count).
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

    /// Capture-side chunk size. 64 across all evaluations.
    static let chunkSize: Int = 64

    private(set) var frames: [Frame] = []
    private(set) var inferenceInflight: Bool = false
    /// Chunk-start indices the live scheduler deferred to the post-session
    /// drain. Stays empty while inference keeps up with capture; grows by
    /// one entry every time `kickInferenceIfReady` sees ≥2 ready chunks.
    private(set) var stash: [Int] = []
    /// Set to `true` once `LiveRecordingScreen` taps Stop. Latches the live
    /// scheduler so `finishInflight` and any later `append` don't kick a
    /// *new* chunk after the user has stopped — which would race the
    /// `PostProcessor`, double-write that chunk's scores (the drain has
    /// already listed it as unscored from the saved mp4), and inflate the
    /// running-average.
    private var isShutdown: Bool = false

    /// Smallest chunk-start the scheduler hasn't decided on yet (neither
    /// scored, nor stashed, nor in-flight). Increments by `chunkSize` each
    /// time the scheduler picks (or skips) a chunk.
    private var nextChunkStart: Int = 0
    /// Chunk-start currently in flight, or -1 when idle.
    private var inflightStart: Int = -1
    /// Lowest frame index that still has a live pixel buffer. Tracked so
    /// `dropOldBuffers` is O(delta) per call instead of O(N).
    private var oldestLivePixelBuffer: Int = 0
    /// Handle on the in-flight inference Task so `awaitInflight()` can wait
    /// for it before the post-session drainer starts (otherwise the live
    /// continuation could double-write the in-flight chunk).
    private var inflightTask: Task<Void, Never>?

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
    /// running-average path the real inference uses.
    func applySyntheticChunk(_ scores: [Float], start: Int) {
        applyChunkScores(scores, start: start)
    }

    /// `PostProcessor` hook — stamp drained-chunk scores back into the per-
    /// frame array. Same code path as live, just labelled separately so
    /// future telemetry can distinguish the two.
    func applyDrainedChunk(_ scores: [Float], start: Int) {
        applyChunkScores(scores, start: start)
    }

    /// Wait for any in-flight live inference to land its scores before the
    /// post-session drainer enumerates pending chunks. Without this, the
    /// drainer could see the in-flight chunk as unscored, queue it for
    /// re-scoring, and end up double-counting once the live continuation
    /// also writes scores (running-sum + count would inflate the average).
    func awaitInflight() async {
        if let task = inflightTask {
            await task.value
        }
    }

    /// Latch the live scheduler so no new chunks are kicked off. Call this
    /// *before* `awaitInflight()` in the Stop path: otherwise the in-flight
    /// chunk's completion handler immediately calls `kickInferenceIfReady`
    /// and a fresh live task starts on top of frames the `PostProcessor` is
    /// about to re-score from the mp4. After `stopScheduling()`, every
    /// remaining unscored chunk in the window is drained exclusively by
    /// `PostProcessor` — no double-write race.
    func stopScheduling() {
        isShutdown = true
    }

    /// Authoritative list of chunk-start indices that still need scoring
    /// after the user taps Stop. Computed by enumerating every full
    /// 64-frame chunk inside `[recordingStart, frames.count)` and keeping
    /// those whose first frame has `scoreCount == 0`. This is robust to
    /// scheduler edge cases (in-flight, stashed, never-scheduled) and to
    /// the live `stash` going stale because of a late-completing inference.
    /// Chunks straddling `recordingStart` (their start is below it) are
    /// dropped — the mp4 only contains frames from Start onward, so we
    /// can't re-decode their pre-recording portion.
    func chunksAwaitingPostProcessing(recordingStart: Int) -> [Int] {
        let chunk = Self.chunkSize
        let total = frames.count
        // First chunk-start at or after `recordingStart`, on the global
        // capture-index grid (chunks are aligned to 0, 64, 128, …).
        let firstStart = ((recordingStart + chunk - 1) / chunk) * chunk
        var pending: [Int] = []
        var s = firstStart
        while s + chunk <= total {
            if frames.indices.contains(s), frames[s].scoreCount == 0 {
                pending.append(s)
            }
            s += chunk
        }
        return pending
    }

    /// Forget the stashed chunk-starts. Called by `PostProcessor` once it's
    /// scored every chunk in `chunksAwaitingPostProcessing`.
    func clearStash() {
        stash.removeAll()
    }

    func reset() {
        frames.removeAll()
        stash.removeAll()
        inferenceInflight = false
        nextChunkStart = 0
        inflightStart = -1
        oldestLivePixelBuffer = 0
        inflightTask = nil
        isShutdown = false
    }

    /// Release pixel buffers we no longer need. With non-overlapping chunks
    /// + the latest-only live policy, only the in-flight chunk's 64 buffers
    /// matter; everything older is either already scored (so the buffer's
    /// served its purpose) or stashed (so the mp4 will re-supply it in
    /// post-processing).
    private func dropOldBuffers() {
        let keepStart = inferenceInflight ? inflightStart : nextChunkStart
        while oldestLivePixelBuffer < keepStart, oldestLivePixelBuffer < frames.count {
            frames[oldestLivePixelBuffer].pixelBuffer = nil
            oldestLivePixelBuffer += 1
        }
    }

    private func kickInferenceIfReady() {
        guard !isShutdown, !inferenceInflight, let inference else { return }
        let chunk = Self.chunkSize
        let total = frames.count
        // Highest chunk-start whose 64 frames are all captured. `-1` means
        // "no full chunk available yet"; the guard below catches that.
        let latestReadyStart = ((total / chunk) - 1) * chunk
        guard latestReadyStart >= nextChunkStart else { return }

        // Stash every ready chunk older than `latestReadyStart` so the post-
        // session drain knows to re-score them. Their pixel buffers can be
        // released right after.
        var s = nextChunkStart
        let stashedThisKick = (s < latestReadyStart) ? (latestReadyStart - s) / chunk : 0
        while s < latestReadyStart {
            stash.append(s)
            s += chunk
        }

        let start = latestReadyStart
        let end = start + chunk - 1
        let buffers = frames[start...end].compactMap { $0.pixelBuffer }
        guard buffers.count == chunk else {
            // We dropped a buffer we still need (shouldn't happen — the
            // dropOldBuffers guard keeps the in-flight chunk's buffers
            // intact). Defensively stash this chunk and advance.
            stash.append(start)
            nextChunkStart = start + chunk
            return
        }

        inferenceInflight = true
        inflightStart = start
        nextChunkStart = start + chunk
        dropOldBuffers()
        // Verification log: `picked` is what we just kicked off; `newest`
        // is the highest chunk-start that was fully captured at this moment.
        // They should ALWAYS be equal — the scheduler picks the latest
        // ready chunk every time. `stashed_this_kick` grows whenever
        // inference falls behind by ≥2 chunks. Watch in Xcode's device
        // console or `idevicesyslog | grep '\[Scheduler\]'`.
        let newest = ((frames.count / chunk) - 1) * chunk
        print(
            "[Scheduler] picked=\(start / chunk)" +
            " newest=\(newest / chunk)" +
            " stashed_this_kick=\(stashedThisKick)" +
            " stash_total=\(stash.count)" +
            " total_frames=\(frames.count)"
        )

        inflightTask = Task.detached { [weak self] in
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
        inflightTask = nil
        dropOldBuffers()
        kickInferenceIfReady()
    }

    private func handleInferenceError(_ error: Error) {
        inferenceInflight = false
        inflightStart = -1
        inflightTask = nil
        onError(error)
    }
}
