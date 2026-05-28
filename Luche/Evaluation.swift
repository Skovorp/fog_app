import Foundation

/// One MDS-UPDRS Part III item the demo exposes. Encoded as a string so the
/// on-disk Session JSON stays stable when we add or rename cases.
enum Evaluation: String, Codable, CaseIterable, Identifiable, Hashable {
    case gait
    case arisingFromChair
    case fingerTapping
    case freezingOfGait

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .arisingFromChair:  return "Arising from Chair"
        case .gait:              return "Walking"
        case .freezingOfGait:    return "Freezing of Gait"
        case .fingerTapping:     return "Finger Tapping"
        }
    }

    var updrsItem: String {
        switch self {
        case .arisingFromChair:  return "MDS-UPDRS 3.9"
        case .gait:              return "MDS-UPDRS 3.10"
        case .freezingOfGait:    return "MDS-UPDRS 3.11"
        case .fingerTapping:     return "MDS-UPDRS 3.4"
        }
    }

    var symbolName: String {
        switch self {
        case .arisingFromChair:  return "figure.stand"
        case .gait:              return "figure.walk"
        case .freezingOfGait:    return "figure.walk.motion"
        case .fingerTapping:     return "hand.tap"
        }
    }

    var instructionTitle: String {
        switch self {
        case .arisingFromChair:  return "Stand up from a chair"
        case .gait:              return "Walk in front of the camera"
        case .freezingOfGait:    return "Turn around in place"
        case .fingerTapping:     return "Tap your fingers"
        }
    }

    var instructionSteps: [String] {
        let common = ["Tap Start when you're ready to begin"]
        switch self {
        case .arisingFromChair:
            return [
                "Sit in a straight-back chair",
                "Cross your arms over your chest",
                "Stand up without using your hands",
                "Repeat 3 times",
            ] + common
        case .gait:
            return [
                "Walk 10 steps away from the camera",
                "Turn around and walk 10 steps back",
            ] + common
        case .freezingOfGait:
            return [
                "Point the camera at your feet",
                "Do one full 360° turn in place",
            ] + common
        case .fingerTapping:
            return [
                "Tap your index finger against your thumb",
                "As quickly and as widely as you can",
                "About 30 taps",
            ] + common
        }
    }

    /// True if this evaluation should headline % FoG frames instead of the
    /// generic 0-4 UPDRS demo score. The shipped model is FoG-trained, so
    /// only this case is properly calibrated for the threshold metric.
    var headlinesFogPct: Bool { self == .freezingOfGait }

    // MARK: Per-evaluation model contract
    //
    // FoG uses the original per-frame classifier (output 64 probabilities in
    // [0,1]). The three regression evaluations (gait/chair/tapping) ship a
    // ViT-B regression head that emits a single denormalized UPDRS score in
    // [0,4] per chunk. Each evaluation's mlpackage is exported from a
    // different training config; the constants below mirror the cfg embedded
    // in the matching .pt checkpoint.

    /// Name of the .mlpackage in the app bundle (sans extension).
    var modelResourceName: String {
        switch self {
        case .freezingOfGait:   return "FreezingModel"
        case .gait:             return "WalkingModel"
        case .arisingFromChair: return "ChairModel"
        case .fingerTapping:    return "TappingModel"
        }
    }

    /// Number of frames the camera buffers per chunk before invoking the
    /// model. 64 across the board so the FrameBarView and capture geometry
    /// stay uniform.
    var captureFramesPerChunk: Int { 64 }

    /// Number of frames actually fed to the model after subsampling. FoG
    /// subsamples to 16; walking / chair / tapping all subsample to 32.
    /// Walking model was re-exported with PE interpolation at 32 frames to
    /// match the latency of the other regression heads.
    var modelInputFrames: Int {
        switch self {
        case .freezingOfGait: return 16   // 64 captured frames, every 4th
        case .gait, .arisingFromChair, .fingerTapping: return 32   // every other
        }
    }

    /// Stride from the capture buffer when building the model input.
    /// `modelInputFrames * frameSubsampleStep == captureFramesPerChunk`.
    var frameSubsampleStep: Int {
        switch self {
        case .freezingOfGait: return 4
        case .gait, .arisingFromChair, .fingerTapping: return 2
        }
    }

    /// How many capture frames the buffer advances between chunks. FoG uses
    /// 50% overlap (32) so per-frame probabilities are averaged across two
    /// chunks. Regression heads emit one number per chunk that gets stamped
    /// to all 64 frames in the window — overlap would just duplicate work.
    var captureChunkShift: Int {
        switch self {
        case .freezingOfGait: return 32   // 50% overlap
        default:              return 64   // no overlap
        }
    }

    /// True if the model returns one probability per capture frame
    /// (`captureFramesPerChunk` outputs). False if it returns a single
    /// chunk-level scalar that should be stamped to every frame in the window.
    var outputIsPerFrame: Bool {
        switch self {
        case .freezingOfGait: return true
        default:              return false
        }
    }

    /// True if the FrameBuffer should drop queued chunks and always jump to
    /// the most recent fully-captured chunk when the model can't keep up.
    /// Leaves visible holes in the score timeline where chunks were skipped.
    /// No evaluation uses this today; kept as a hook for future slow heads.
    var skipQueuedChunks: Bool { false }

    /// Spatial input size H=W in pixels — matches what the matching mlpackage
    /// was exported at. All current models are 256².
    var modelSpatialSize: Int { 256 }

    /// Filename (sans extension) of the looping demo video in the bundle.
    /// Returns nil when no .mp4 has been added yet — the instruction screen
    /// falls back to the SF Symbol / static image in that case.
    ///
    /// **Spec for new clips** — match the existing `FingerTappingDemo.mp4`:
    ///   - **Subject**: framed hand / body part performing the gesture from
    ///     the camera's POV. No clinician on screen, no narration.
    ///   - **Background**: neutral (plain wall / table). The viewer's eye
    ///     should land on the motion, not the room.
    ///   - **Length**: ~5–10 s, end-frame visually close to the start-frame
    ///     so the AVPlayerLooper loop seam is invisible.
    ///   - **Resolution**: ~480p (h = 480, width keeps aspect). Anything
    ///     larger just bloats the bundle — the player frame is ≤380×220 pt.
    ///   - **Codec**: H.264 baseline, yuv420p, +faststart, no audio track.
    ///   - **Size**: target < 500 KB per clip. The finger-tapping reference
    ///     is 346 KB at 878×480 CRF 28 — use it as the budget.
    ///   - **Encode command** (mirrors what shipped):
    ///       ```
    ///       ffmpeg -i in.mp4 -an -c:v libx264 -profile:v baseline -level 4.0 \
    ///           -pix_fmt yuv420p -crf 28 -preset slow -movflags +faststart \
    ///           -vf "scale=-2:480" <Name>Demo.mp4
    ///       ```
    var demoVideoResource: String? {
        switch self {
        case .gait:               return "WalkingDemo"
        case .arisingFromChair:   return "ChairDemo"
        case .fingerTapping:      return "FingerTappingDemo"
        case .freezingOfGait:     return "FreezingDemo"
        }
    }
}
