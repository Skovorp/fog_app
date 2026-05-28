import Foundation
import ClerkKit

/// Talks to feral-api for the "Share with your doctor" flow:
///   1. Ask backend for a presigned R2 PUT URL (auth: Clerk session JWT).
///   2. PUT the local zip to that URL with progress reporting.
///
/// All network work happens off the main actor; callers should await on a
/// background Task and hop back to MainActor for UI updates. Progress callbacks
/// fire on URLSession's delegate queue (also off-main) — UI consumers must
/// dispatch onto MainActor before mutating @State.
enum UploadClient {

    /// Backend base URL. Pi-hosted prod tunnel, documented in
    /// wiki/ops-infra/pi/feral-api.md. Move to xcconfig if/when staging exists.
    private static let apiBase = URL(string: "https://feral-api.ratemepls.com")!

    enum UploadError: LocalizedError {
        case notAuthenticated
        case localFileMissing
        case requestURLFailed(status: Int, body: String)
        case uploadFailed(status: Int, body: String)
        case invalidResponse
        // Per-trial flow (Flow A):
        case videoMissing               // no on-disk mp4 for this session
        case badTestType                // 400 bad_test_type from /trials or /uploads/request-url
        case uploadForbidden            // 403 upload_forbidden (unknown/expired/foreign upload_id)
        case uploadNotFound             // 422 upload_not_found (R2 head_object 404)
        case invalidTrial(code: String, body: String)  // generic 400 that ISN'T bad_test_type
        case trialFailed(status: Int, code: String, body: String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in. Sign in and try again."
            case .localFileMissing:
                return "Couldn't read the bundled zip file."
            case .requestURLFailed(let status, let body):
                return "Couldn't get an upload URL (HTTP \(status)). \(body.prefix(200))"
            case .uploadFailed(let status, let body):
                return "Upload failed (HTTP \(status)). \(body.prefix(200))"
            case .invalidResponse:
                return "Server response could not be read."
            case .videoMissing:
                return "This session has no recorded video to upload."
            case .badTestType:
                return "This test type isn't recognized by the server."
            case .uploadForbidden:
                return "The upload couldn't be authorized. Please try again."
            case .uploadNotFound:
                return "The video didn't finish uploading. Please try again."
            case .invalidTrial(let code, let body):
                let detail = code.isEmpty ? body.prefix(160).description : code
                return "The server rejected this trial (400). \(detail)"
            case .trialFailed(let status, let code, let body):
                let detail = code.isEmpty ? body.prefix(160).description : code
                return "Couldn't save the trial (HTTP \(status)). \(detail)"
            }
        }
    }

    // MARK: - Per-trial upload (Flow A)
    //
    // For each Session the patient syncs:
    //   a. POST /uploads/request-url {test_type_id, size_bytes} → {upload_url, upload_id, expires_in}
    //   b. PUT the trial mp4 to upload_url with Content-Type video/mp4
    //   c. POST /trials {upload_id, test_type_id, recorded_at, score, metadata, client_trial_id}
    // The server owns the R2 key (§5.3) — the client only ever sees upload_id.

    private struct RequestTrialURLResponse: Decodable {
        let upload_url: String
        let upload_id: String
        let expires_in: Int
    }

    private struct PostTrialResponse: Decodable {
        let trial_id: Int
        let status: String   // "created" | "exists" — both are success
    }

    /// Step a. Ask the backend for a per-trial presigned R2 PUT URL.
    /// Returns `(uploadURL, uploadId)`. The raw R2 key is never returned to us.
    static func requestTrialUploadURL(
        testTypeId: String,
        sizeBytes: Int
    ) async throws -> (uploadURL: URL, uploadId: String) {
        let body: [String: Any] = [
            "test_type_id": testTypeId,
            "size_bytes": sizeBytes,
        ]
        var req = URLRequest(url: apiBase.appendingPathComponent("uploads/request-url"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 { throw UploadError.badTestType }
            throw UploadError.requestURLFailed(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let decoded: RequestTrialURLResponse
        do {
            decoded = try JSONDecoder().decode(RequestTrialURLResponse.self, from: data)
        } catch {
            throw UploadError.invalidResponse
        }
        guard let url = URL(string: decoded.upload_url) else { throw UploadError.invalidResponse }
        return (url, decoded.upload_id)
    }

    /// Step b. PUT a trial's mp4 to R2. Content-Type MUST be `video/mp4` to
    /// match the presigned-URL signature the server minted.
    static func putVideo(
        fileURL: URL,
        uploadURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (data, response) = try await URLSession.shared.upload(
            for: req, fromFile: fileURL, delegate: delegate
        )
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw UploadError.uploadFailed(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    /// Step c. Record the trial. Treats 200 `exists` and 201 `created` as
    /// success (idempotent on `client_trial_id`). Maps 400/403/422 to typed
    /// errors so the UI can branch.
    @discardableResult
    static func postTrial(
        uploadId: String,
        testTypeId: String,
        recordedAt: Date,
        score: Double,
        metadata: [String: Any],
        clientTrialId: String
    ) async throws -> (trialId: Int, status: String) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body: [String: Any] = [
            "upload_id": uploadId,
            "test_type_id": testTypeId,
            "recorded_at": iso.string(from: recordedAt),
            "score": score,
            "metadata": metadata,
            "client_trial_id": clientTrialId,
        ]
        var req = URLRequest(url: apiBase.appendingPathComponent("trials"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }

        // 200 (exists) and 201 (created) are both success.
        guard (200...201).contains(http.statusCode) else {
            let code = Self.errorCode(data)
            switch http.statusCode {
            case 400:
                // Only `bad_test_type` is the typed test-type error. Any other
                // 400 (e.g. a malformed/missing-field payload) is a generic
                // validation failure — don't mislabel it as a bad test type.
                if code == "bad_test_type" {
                    throw UploadError.badTestType
                }
                throw UploadError.invalidTrial(
                    code: code,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            case 403: throw UploadError.uploadForbidden
            case 422: throw UploadError.uploadNotFound
            default:
                throw UploadError.trialFailed(
                    status: http.statusCode,
                    code: code,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            }
        }
        let decoded: PostTrialResponse
        do {
            decoded = try JSONDecoder().decode(PostTrialResponse.self, from: data)
        } catch {
            throw UploadError.invalidResponse
        }
        return (decoded.trial_id, decoded.status)
    }

    /// Orchestrates a–c for a single session. Resolves the on-disk mp4 via
    /// VideoStore, sizes it, presigns, PUTs, then records the trial. The
    /// headline `score` follows §5.1 (fogPct for FoG, avgProbability otherwise).
    /// `onProgress` reports the PUT progress for this one video in [0, 1].
    ///
    /// Nonisolated so the SessionStore drain can call it off the main actor.
    /// `device` is captured by the caller on the main actor (since
    /// `DeviceInfo.current()` is `@MainActor`) and threaded through to the
    /// metadata builder.
    static func uploadTrial(
        session: Session,
        device: DeviceInfo,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let fileURL = VideoStore.existingURL(for: session) else {
            throw UploadError.videoMissing
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = (attrs?[.size] as? NSNumber)?.intValue, size > 0 else {
            throw UploadError.videoMissing
        }

        let evaluation = session.effectiveEvaluation
        let testTypeId = evaluation.rawValue
        // §5.1: FoG headlines % of frames ≥ 0.5 (0–100); the regression heads
        // headline the mean per-frame [0–1] severity.
        let score: Double = evaluation.headlinesFogPct ? session.fogPct : session.avgProbability
        let metadata = SessionExport.trialMetadata(for: session, fallbackDevice: device)

        // a. presign (+ pending_uploads row server-side)
        let (uploadURL, uploadId) = try await requestTrialUploadURL(
            testTypeId: testTypeId,
            sizeBytes: size
        )
        // b. PUT the video to R2 BEFORE recording the trial (§ Flow A ordering):
        //    the server HEADs R2 in step c, so a row only ever exists for a
        //    video that's actually present.
        try await putVideo(fileURL: fileURL, uploadURL: uploadURL, onProgress: onProgress)
        // c. record the trial (idempotent on client_trial_id == Session.id)
        _ = try await postTrial(
            uploadId: uploadId,
            testTypeId: testTypeId,
            recordedAt: session.startedAt,
            score: score,
            metadata: metadata,
            clientTrialId: session.id.uuidString
        )
    }

    // MARK: Shared helpers

    /// Clerk session JWT, or throws `.notAuthenticated`.
    private static func bearer() async throws -> String {
        guard let session = await Clerk.shared.session else { throw UploadError.notAuthenticated }
        guard let jwt = try await session.getToken(), !jwt.isEmpty else {
            throw UploadError.notAuthenticated
        }
        return jwt
    }

    /// Pulls the `error` machine code from a `{"error":...}` body.
    private static func errorCode(_ data: Data) -> String {
        struct ErrBody: Decodable { let error: String? }
        return (try? JSONDecoder().decode(ErrBody.self, from: data))?.error ?? ""
    }
}

/// Per-task delegate. Throttles progress to ~1% deltas so the consumer isn't
/// hammered with one update per packet (a 1 GB upload over a chunky cell link
/// is otherwise ~thousands of callbacks). Ordering is enforced consumer-side
/// via max() when aggregating progress across multiple trials.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: (@Sendable (Double) -> Void)?
    private var lastReported: Double = 0
    private let queue = DispatchQueue(label: "luche.upload.progress")

    init(onProgress: (@Sendable (Double) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let shouldEmit: Bool = queue.sync {
            if fraction - lastReported >= 0.01 || fraction >= 1.0 {
                lastReported = fraction
                return true
            }
            return false
        }
        if shouldEmit { onProgress?(fraction) }
    }
}
