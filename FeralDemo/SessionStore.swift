import Foundation
import Observation

/// Persists `Session`s to Application Support as a single JSON file.
/// Sessions are kept newest-first.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("sessions.json")
        load()
    }

    func add(_ session: Session) {
        sessions.insert(session, at: 0)
        persist()
    }

    func delete(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        if let filename = session.videoFilename {
            VideoStore.delete(filename: filename)
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        let removed = offsets.map { sessions[$0] }
        sessions.remove(atOffsets: offsets)
        for session in removed {
            if let filename = session.videoFilename {
                VideoStore.delete(filename: filename)
            }
        }
        persist()
    }

    func clear() {
        sessions.removeAll()
        VideoStore.deleteAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let loaded = try decoder.decode([Session].self, from: data)
            self.sessions = loaded.sorted { $0.startedAt > $1.startedAt }
        } catch {
            print("[SessionStore] decode failed: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[SessionStore] persist failed: \(error.localizedDescription)")
        }
    }
}
