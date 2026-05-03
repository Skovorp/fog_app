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

    /// Threshold above which a frame is counted as "fog". 0.5 matches the
    /// model's default operating point — RESULTS.md run_06 (the no-pool
    /// 256/16f/step4 config) is well-calibrated at this threshold.
    static let fogThreshold: Float = 0.5

    var totalFrames: Int { scores.count }
    var fogCount: Int { scores.lazy.filter { $0 >= Self.fogThreshold }.count }
    var fogPct: Double {
        guard !scores.isEmpty else { return 0 }
        return Double(fogCount) / Double(scores.count) * 100
    }
    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

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
}
