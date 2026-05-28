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

    /// Number of frames fed to the model per chunk. 64 every-frame across
    /// all heads — matches the recipe each checkpoint was trained on
    /// (`chunk_length: 64, chunk_step: 1`). Prior exports subsampled to
    /// 16/32 frames for latency; that's been moved off the model and onto
    /// the live scheduler (skip-to-latest + end-of-session drain) instead.
    var modelInputFrames: Int { 64 }

    /// Stride from the capture buffer when building the model input. Always
    /// 1 — `modelInputFrames * frameSubsampleStep == captureFramesPerChunk`.
    var frameSubsampleStep: Int { 1 }

    /// How many capture frames the buffer advances between chunks. Always
    /// 64 (non-overlapping) so each capture frame belongs to exactly one
    /// chunk — live skip-to-latest stashes the unscored chunks and the
    /// post-session drain fills them in with no double-counting.
    var captureChunkShift: Int { 64 }

    /// True if the model returns one probability per capture frame
    /// (`captureFramesPerChunk` outputs). False if it returns a single
    /// chunk-level scalar that should be stamped to every frame in the window.
    var outputIsPerFrame: Bool {
        switch self {
        case .freezingOfGait: return true
        default:              return false
        }
    }

    /// Per-evaluation display / clamp range for a single frame score.
    ///   - FoG: per-frame fog probability in [0, 1].
    ///   - Chair: 0–1. Training labels for `exp_chair_strong_with_negs` are
    ///     50% raw=0 and 50% raw=1, never 2–4, so clamping above 1 is noise.
    ///   - Walking / Tapping: raw MDS-UPDRS 0–4 scale. Training labels span
    ///     0–3 with mean ≈ 1.1; we expose the full 0–4 schema so the bar
    ///     can show severe-end outliers if they appear.
    /// See `wiki/ios-app/symptoms/<head>` for train-label histograms.
    var scoreRange: ClosedRange<Float> {
        switch self {
        case .freezingOfGait, .arisingFromChair: return 0.0...1.0
        case .gait, .fingerTapping:              return 0.0...4.0
        }
    }

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
