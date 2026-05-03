import Foundation

/// On-disk videos directory inside Application Support. One `<UUID>.mp4` per
/// session. Videos are intentionally NOT inside Documents (which is exposed
/// to the Files app and iCloud Drive) — clinical recordings stay private to
/// the app sandbox until the user explicitly exports them.
enum VideoStore {
    static let directory: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("videos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func fileURL(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Returns the on-disk URL only when the file actually exists. Sessions
    /// from older builds (no `videoFilename`) and sessions whose video was
    /// already removed both return nil.
    static func existingURL(for session: Session) -> URL? {
        guard let filename = session.videoFilename else { return nil }
        let url = fileURL(for: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func fileSizeBytes(for session: Session) -> Int64? {
        guard let url = existingURL(for: session) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    static func delete(filename: String) {
        let url = fileURL(for: filename)
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files {
            try? fm.removeItem(at: url)
        }
    }

    /// "5.2 MB" — short, human-readable.
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
