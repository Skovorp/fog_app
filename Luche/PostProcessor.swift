import AVFoundation
import CoreVideo
import Foundation
import Observation

/// Drives the post-session "fill in skipped chunks" loop.
///
/// During live recording the scheduler aggressively skips chunks so the
/// score bar stays current; skipped chunks are stashed (just their start
/// indices — no pixel buffers retained). When the user taps Stop, the mp4
/// the camera wrote in real time is *every* recorded frame on disk, so we
/// can re-decode the stashed chunks from it and run inference per chunk.
///
/// `PostProcessor` owns strong references to `FrameBuffer` and `Inference`
/// so the phase transition `.live → .processing → .results` doesn't deinit
/// them mid-drain.
@MainActor
@Observable
final class PostProcessor: Equatable {
    nonisolated static func == (lhs: PostProcessor, rhs: PostProcessor) -> Bool {
        lhs === rhs
    }

    /// Number of pending chunks already drained. Drives the ring chart.
    private(set) var processed: Int = 0
    /// Total chunks to drain. Snapshotted at init so late live-scoring
    /// doesn't shift the denominator mid-progress.
    let total: Int
    private(set) var isFinished: Bool = false
    /// `nil` while running / after success; non-nil if the AVAssetReader
    /// pass failed. The drain still calls `onFinished` either way — failing
    /// closed lets the caller decide what to do with a partial Session.
    private(set) var lastError: String?

    let buffer: FrameBuffer
    let inference: Inference
    let videoURL: URL
    let recordingStart: Int
    private let pending: [Int]
    private var onFinished: (() -> Void)?

    init(buffer: FrameBuffer,
         inference: Inference,
         videoURL: URL,
         recordingStartFrameIndex: Int) {
        self.buffer = buffer
        self.inference = inference
        self.videoURL = videoURL
        self.recordingStart = recordingStartFrameIndex
        let pendingList = buffer.chunksAwaitingPostProcessing(recordingStart: recordingStartFrameIndex)
        self.pending = pendingList
        self.total = pendingList.count
    }

    /// Begin draining. `onFinished` fires on the main actor when the loop
    /// completes (or fails) — at that point every drainable chunk has been
    /// scored back into `buffer.frames` and `buffer.clearStash()` has run.
    func start(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        if pending.isEmpty {
            buffer.clearStash()
            isFinished = true
            onFinished()
            return
        }
        Task { await drain() }
    }

    private func drain() async {
        do {
            try await decodeAndScore()
        } catch {
            lastError = error.localizedDescription
            print("[PostProcessor] drain failed: \(error.localizedDescription)")
        }
        buffer.clearStash()
        isFinished = true
        onFinished?()
    }

    /// Sequential pass over the saved mp4. mp4-frame *i* maps to
    /// `FrameBuffer` index `recordingStart + i` (the mp4 starts at the
    /// Start tap; the FrameBuffer started indexing from the camera's first
    /// preview frame). Each pending chunk's 64 frames are collected and
    /// fed to `Inference.run` as soon as the 64th arrives.
    private func decodeAndScore() async throws {
        let pendingSet = Set(pending)
        let chunkSize = FrameBuffer.chunkSize
        let recordingStart = self.recordingStart
        let url = self.videoURL
        let inference = self.inference

        // Heavy decode + per-chunk inference run off the main actor.
        try await Task.detached(priority: .userInitiated) { [weak self] in
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw NSError(
                    domain: "Luche.PostProcessor", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Saved video has no video track"]
                )
            }

            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = true
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? NSError(domain: "Luche.PostProcessor", code: 2)
            }

            var buffers: [Int: [CVPixelBuffer]] = [:]
            var mp4Index = 0
            while reader.status == .reading {
                guard let sample = output.copyNextSampleBuffer() else { break }
                if let pixel = CMSampleBufferGetImageBuffer(sample) {
                    let captureIdx = mp4Index + recordingStart
                    let chunkStart = (captureIdx / chunkSize) * chunkSize
                    if pendingSet.contains(chunkStart) {
                        buffers[chunkStart, default: []].append(pixel)
                        if buffers[chunkStart]?.count == chunkSize {
                            let bufs = buffers.removeValue(forKey: chunkStart) ?? []
                            let scores = try await inference.run(buffers: bufs)
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.buffer.applyDrainedChunk(scores, start: chunkStart)
                                self.processed += 1
                            }
                        }
                    }
                }
                mp4Index += 1
            }
            if reader.status == .failed {
                throw reader.error ?? NSError(domain: "Luche.PostProcessor", code: 3)
            }
            // Defensive: clean up any chunk that didn't accumulate a full 64
            // frames (mp4 ended mid-chunk). Those frames stay unscored;
            // `Session.scores` will drop them at save time.
            _ = self  // keep the weak self alive past the loop for readability
        }.value
    }
}
