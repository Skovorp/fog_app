import Foundation
import Observation

/// Persists `Session`s to Application Support as a single JSON file.
/// Sessions are kept newest-first.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    /// The set of `Session.id`s that have been successfully uploaded as trials.
    /// A session is eligible for the next sync iff it has an on-disk video AND
    /// its id is NOT in this set. Per-id (not a time watermark) so a failed
    /// older session isn't permanently skipped when a newer one succeeds.
    /// Idempotency on `client_trial_id` (== Session.id) makes a re-upload of an
    /// already-synced session a harmless server no-op, so an empty set on first
    /// run (migration) is safe.
    private(set) var uploadedIDs: Set<UUID> = []

    /// Cloud sync master switch. Default false (privacy-first). When true, each
    /// finished recording is uploaded automatically while the app is open, and
    /// any previously-unsynced trials backfill on toggle-on / app launch.
    /// Persisted alongside `uploadedIDs` in `upload_state.json`.
    private(set) var syncEnabled: Bool = false
    /// True while a drain pass is actively uploading. Drives the main-screen
    /// "uploading… please keep the app open" banner and the Data sharing
    /// screen status line.
    private(set) var isSyncing: Bool = false
    /// True iff the most recently completed drain pass had at least one upload
    /// failure. Set as a per-pass aggregate (not cleared by a later success
    /// inside the same pass) so the status line reflects "couldn't sync — will
    /// retry" as long as anything is left unsynced after a pass.
    private(set) var lastSyncFailed: Bool = false

    /// In-flight drain task. nil iff no drain is running.
    private var drainTask: Task<Void, Never>?
    /// Set by `triggerSync()` if a drain is already running, so the running
    /// drain picks up sessions added mid-pass (e.g., a new recording finishing
    /// while a backfill is still uploading). Failures never set this — they
    /// rely on the next external trigger to retry, which avoids tight loops on
    /// a permanently-failing session.
    private var needsRerun: Bool = false

    private let fileURL: URL
    private let uploadStateURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("sessions.json")
        self.uploadStateURL = dir.appendingPathComponent("upload_state.json")
        load()
        loadUploadState()
    }

    /// Sessions that still need uploading: have a recorded video AND haven't yet
    /// synced successfully. Newest-first (inherits `sessions` ordering).
    var sessionsToUpload: [Session] {
        sessions.filter { VideoStore.existingURL(for: $0) != nil && !uploadedIDs.contains($0.id) }
    }

    /// Total sessions eligible for cloud sync (i.e. those with an on-disk
    /// video). Simulator runs and any session whose mp4 was deleted are
    /// excluded so "N of M videos synced" never shows a forever-impossible M.
    var uploadableCount: Int {
        sessions.lazy.filter { VideoStore.existingURL(for: $0) != nil }.count
    }
    /// Subset of `uploadableCount` that has been successfully uploaded.
    var syncedCount: Int {
        sessions.lazy.filter { VideoStore.existingURL(for: $0) != nil && self.uploadedIDs.contains($0.id) }.count
    }

    /// Record a session id as successfully uploaded (after its `/trials` POST
    /// returns 201 created or 200 exists). Persists immediately so a crash
    /// between trials doesn't lose progress.
    func markUploaded(_ id: UUID) {
        guard uploadedIDs.insert(id).inserted else { return }
        persistUploadState()
    }

    func add(_ session: Session) {
        sessions.insert(session, at: 0)
        persist()
        // Hook for in-app background upload: `LiveRecordingScreen.stopAndSave`
        // already awaits `camera.stop()` (mp4 finalize) before calling add(),
        // so the video file is guaranteed on disk by the time we trigger here.
        if syncEnabled { triggerSync() }
    }

    // MARK: - Cloud sync orchestration

    /// Flip the master sync switch. Persists immediately. Turning ON kicks an
    /// immediate backfill drain; turning OFF cancels any in-flight drain (the
    /// drain checks `syncEnabled` / `Task.isCancelled` before each upload and
    /// again after each await, so it won't `markUploaded` an upload that races
    /// past the toggle).
    func setSyncEnabled(_ enabled: Bool) {
        guard syncEnabled != enabled else { return }
        syncEnabled = enabled
        persistUploadState()
        if enabled {
            triggerSync()
        } else {
            drainTask?.cancel()
        }
    }

    /// Idempotent entry point: either starts a drain or marks the running one
    /// for one more pass (so a recording that finishes mid-backfill is picked
    /// up without queueing a second concurrent drain). Safe to call from any
    /// MainActor context — `SessionStore` is `@MainActor`, so the
    /// drainTask-nil check + assignment is serialized.
    func triggerSync() {
        guard syncEnabled else { return }
        if drainTask != nil {
            needsRerun = true
            return
        }
        drainTask = Task { [weak self] in await self?.drain() }
    }

    /// Serial drain loop. Each pass snapshots `sessionsToUpload`, uploads each
    /// once, and stops. A per-pass `hadFailure` flag (not cleared by a later
    /// success in the same pass) drives `lastSyncFailed` so the UI can show
    /// "couldn't sync — will retry" while anything is still unsynced. The
    /// next external trigger (new recording, toggle-on, launch catch-up)
    /// retries failed sessions.
    private func drain() async {
        defer {
            isSyncing = false
            drainTask = nil
        }
        // `DeviceInfo.current()` is @MainActor; snapshot here (on main) and
        // pass the value into the nonisolated `uploadTrial` so the network
        // call runs fully off the main actor.
        let device = DeviceInfo.current()
        repeat {
            needsRerun = false
            let pending = sessionsToUpload
            guard !pending.isEmpty else { return }
            isSyncing = true
            var hadFailure = false
            for session in pending {
                if !syncEnabled || Task.isCancelled { return }
                do {
                    try await UploadClient.uploadTrial(session: session, device: device)
                    // Re-check after the await: if the user flipped sync off
                    // (or cancelled the task) while the PUT was in flight,
                    // don't mutate sync state. The server-side trial may
                    // still have landed; that's acceptable (the next OFF
                    // confirmation explicitly says past videos stay in the
                    // cloud unless deleted).
                    if !syncEnabled || Task.isCancelled { return }
                    // Also skip markUploaded if the user deleted this
                    // session locally mid-flight — otherwise `uploadedIDs`
                    // accumulates an orphan id no `sessions` entry maps to.
                    // `syncedCount/uploadableCount` both filter over
                    // `sessions`, so a stale id wouldn't be a visible
                    // count lie, but it's cruft that drifts our local
                    // "what's synced" state out of sync with `sessions`.
                    // The server-side trial may still have landed; that
                    // matches the same "uploaded copies persist on the
                    // server until cloud deletion ships" contract.
                    guard self.sessions.contains(where: { $0.id == session.id }) else { continue }
                    markUploaded(session.id)
                } catch {
                    // Cancellation (toggle OFF, app teardown, URL task cancel)
                    // isn't a real upload failure — return without flagging,
                    // so the UI doesn't flash "couldn't sync — will retry"
                    // when sync flips back on later.
                    if Task.isCancelled { return }
                    hadFailure = true
                    // Skip; don't retry within the same pass. Next external
                    // trigger will re-attempt.
                }
            }
            lastSyncFailed = hadFailure
        } while needsRerun && syncEnabled && !Task.isCancelled
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

    /// On-disk upload state. `uploadedIDs` is the per-session sync set;
    /// `syncEnabled` is the cloud-sync master switch. The legacy
    /// `lastUploadedAt` watermark is still decoded (optional) so an existing
    /// install migrates gracefully — but it's no longer used to gate uploads.
    /// Re-uploading an already-synced session is a server no-op (idempotent on
    /// client_trial_id), so dropping the watermark is safe. New installs and
    /// upgrades-without-prior-state default `syncEnabled` to false
    /// (privacy-first: nothing leaves the device until the user opts in).
    private struct UploadState: Codable {
        let uploadedIDs: [UUID]?
        let lastUploadedAt: Date?   // legacy; ignored on read
        let syncEnabled: Bool?
    }

    private func loadUploadState() {
        guard let data = try? Data(contentsOf: uploadStateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let state = try? decoder.decode(UploadState.self, from: data) {
            self.uploadedIDs = Set(state.uploadedIDs ?? [])
            self.syncEnabled = state.syncEnabled ?? false
        }
    }

    private func persistUploadState() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let state = UploadState(
                uploadedIDs: Array(uploadedIDs),
                lastUploadedAt: nil,
                syncEnabled: syncEnabled
            )
            let data = try encoder.encode(state)
            try data.write(to: uploadStateURL, options: .atomic)
        } catch {
            print("[SessionStore] persist upload state failed: \(error.localizedDescription)")
        }
    }
}
