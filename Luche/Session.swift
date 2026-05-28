import Foundation

/// One recording session: per-frame fog probabilities plus start/end metadata.
/// Only frames that received a model score are stored — trailing unscored
/// frames (an in-flight chunk at stop time) are dropped at save time.
struct Session: Identifiable, Codable, Hashable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let scores: [Float]
    /// Optional for backward compatibility — sessions saved before device-info
    /// capture was added decode with `device == nil`.
    let device: DeviceInfo?
    /// `<UUID>.mp4` filename inside `VideoStore.directory`. Optional so
    /// sessions saved before video capture decode with `videoFilename == nil`.
    let videoFilename: String?
    /// Which MDS-UPDRS item the user was performing. Optional for backward
    /// compatibility — sessions saved before the multi-evaluation menu decode
    /// with `evaluation == nil` and are treated as `.freezingOfGait` via
    /// `effectiveEvaluation`. Unknown raw values (e.g., a removed enum case)
    /// also decode to nil — see custom `init(from:)` — so retiring an
    /// evaluation doesn't poison the whole `[Session]` decode.
    let evaluation: Evaluation?

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        scores: [Float],
        device: DeviceInfo?,
        videoFilename: String?,
        evaluation: Evaluation?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.scores = scores
        self.device = device
        self.videoFilename = videoFilename
        self.evaluation = evaluation
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, scores, device, videoFilename, evaluation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.endedAt = try c.decode(Date.self, forKey: .endedAt)
        self.scores = try c.decode([Float].self, forKey: .scores)
        self.device = try c.decodeIfPresent(DeviceInfo.self, forKey: .device)
        self.videoFilename = try c.decodeIfPresent(String.self, forKey: .videoFilename)
        // Tolerate unknown raw values (case removed in a later build) by
        // falling back to nil rather than failing the whole array decode.
        if let raw = try c.decodeIfPresent(String.self, forKey: .evaluation) {
            self.evaluation = Evaluation(rawValue: raw)
        } else {
            self.evaluation = nil
        }
    }

    /// Threshold above which a frame is counted as "fog". 0.5 matches the
    /// FoG classifier's operating point. Only meaningful for the FoG head —
    /// the regression heads use the evaluation's full `scoreRange` instead.
    static let fogThreshold: Float = 0.5

    var totalFrames: Int { scores.count }
    var fogCount: Int { scores.lazy.filter { $0 >= Self.fogThreshold }.count }
    var fogPct: Double {
        guard !scores.isEmpty else { return 0 }
        return Double(fogCount) / Double(scores.count) * 100
    }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Mean of the per-frame scores. Range matches the evaluation's
    /// `scoreRange.upperBound`: [0, 1] for FoG / chair, [0, 4] for walking /
    /// tapping (raw MDS-UPDRS). For regression heads this is a clamped mean
    /// of one scalar per chunk stamped onto its frames.
    var avgProbability: Double {
        guard !scores.isEmpty else { return 0 }
        let sum = scores.reduce(Float(0), +)
        return Double(sum) / Double(scores.count)
    }
    /// Headline severity score. Name kept for backward-compat with stored
    /// sessions; the *range* now depends on `effectiveEvaluation.scoreRange`
    /// — 0..1 for chair, 0..4 for walking / tapping.
    var updrsScore: Double { avgProbability }
    /// Five-bucket band over the evaluation's full score range. We normalize
    /// `updrsScore` by `scoreRange.upperBound` so the bucket boundaries (12.5
    /// / 37.5 / 62.5 / 87.5 % of range) line up with chair's old [0,1]
    /// thresholds *and* walking / tapping's [0,4] scale.
    var updrsBand: String {
        let upper = Double(effectiveEvaluation.scoreRange.upperBound)
        let normalized = updrsScore / Swift.max(upper, .leastNonzeroMagnitude)
        switch normalized {
        case ..<0.125: return "Normal"
        case ..<0.375: return "Slight"
        case ..<0.625: return "Mild"
        case ..<0.875: return "Moderate"
        default:       return "Severe"
        }
    }

    var effectiveEvaluation: Evaluation { evaluation ?? .freezingOfGait }

    /// e.g. "April 30 morning"
    var displayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return "\(f.string(from: startedAt)) \(timeOfDay)"
    }

    var timeOfDay: String {
        let h = Calendar.current.component(.hour, from: startedAt)
        switch h {
        case 6..<12:  return "morning"
        case 12..<17: return "afternoon"
        case 17..<23: return "evening"
        default:      return "night"  // 23..<24 and 0..<6
        }
    }

    /// e.g. "Apr 30, 2026 · 10:42 AM"
    var timestampString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: startedAt)
    }

    /// "yyyy-MM-dd_HH-mm" — safe for filenames.
    var filenameStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.string(from: startedAt)
    }

    /// "Walking_2026-05-21_10-42" — used as the PDF download filename so users
    /// can tell sessions apart in their downloads folder.
    var exportFilenameStem: String {
        let safe = effectiveEvaluation.displayName
            .replacingOccurrences(of: " ", with: "_")
        return "\(safe)_\(filenameStamp)"
    }
}
