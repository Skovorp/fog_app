import Foundation
import ClerkKit

/// Centralized client for the Luche sharing API on feral-api.
///
/// Owns: the base URL, Clerk JWT attachment, JSON encode/decode (iso8601),
/// and typed request helpers + Codable response structs for each endpoint
/// defined in `feral-api/API_CONTRACT.md`.
///
/// All network work happens off the main actor; callers should await on a
/// background Task and hop back to MainActor for UI updates. This mirrors the
/// existing `UploadClient` style (async/throws, per-call URLSession).
enum APIClient {

    /// Backend base URL. Pi-hosted prod tunnel, documented in
    /// wiki/ops-infra/pi/feral-api.md. Move to xcconfig if/when staging exists.
    static let apiBase = URL(string: "https://feral-api.ratemepls.com")!

    // MARK: Errors

    /// Typed API errors. `LocalizedError` so `.localizedDescription` surfaces a
    /// human string straight into the existing alert UI.
    enum APIError: LocalizedError {
        case notAuthenticated
        /// Non-2xx response. `code` is the machine code from the
        /// `{"error":"<code>"}` body when present (else the empty string).
        case http(status: Int, code: String, body: String)
        case invalidResponse
        case localFileMissing

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in. Sign in and try again."
            case .http(let status, let code, let body):
                if !code.isEmpty {
                    return "Server error (\(status)): \(code)."
                }
                return "Server error (HTTP \(status)). \(body.prefix(160))"
            case .invalidResponse:
                return "Server response could not be read."
            case .localFileMissing:
                return "Couldn't read the local file."
            }
        }

        /// The machine code (`{"error":...}`) if this is an `.http` error.
        var machineCode: String? {
            if case .http(_, let code, _) = self, !code.isEmpty { return code }
            return nil
        }

        var statusCode: Int? {
            if case .http(let status, _, _) = self { return status }
            return nil
        }
    }

    // MARK: ISO8601 helpers

    /// Shared ISO8601 formatter with fractional seconds, matching the
    /// `recorded_at`/`started_at` strings the rest of the app emits
    /// (SessionExport uses `[.withInternetDateTime, .withFractionalSeconds]`).
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lenient parser for server-supplied ISO8601 timestamps (with or without
    /// fractional seconds — Postgres `timestamptz` may render either way).
    static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: Auth

    /// Fetches the current Clerk session JWT. Throws `.notAuthenticated` if
    /// signed out / token unavailable.
    static func clerkToken() async throws -> String {
        guard let session = await Clerk.shared.session else {
            throw APIError.notAuthenticated
        }
        guard let jwt = try await session.getToken(), !jwt.isEmpty else {
            throw APIError.notAuthenticated
        }
        return jwt
    }

    // MARK: Generic JSON request

    /// Sends an authenticated JSON request and decodes the body to `T`.
    /// `acceptableStatuses` lets idempotent endpoints treat both 200 and 201 as
    /// success while still surfacing the status to the caller.
    @discardableResult
    static func send<T: Decodable>(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        acceptableStatuses: Set<Int> = Set(200..<300),
        decode: T.Type
    ) async throws -> (value: T, status: Int) {
        let (data, status) = try await sendRaw(
            method: method, path: path, body: body,
            acceptableStatuses: acceptableStatuses
        )
        do {
            let value = try jsonDecoder().decode(T.self, from: data)
            return (value, status)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Sends an authenticated JSON request, returning the raw body + status.
    /// Throws `.http` for any status outside `acceptableStatuses`, decoding the
    /// `{"error":...}` machine code so callers can branch on it.
    @discardableResult
    static func sendRaw(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        acceptableStatuses: Set<Int> = Set(200..<300)
    ) async throws -> (data: Data, status: Int) {
        let jwt = try await clerkToken()
        var req = URLRequest(url: apiBase.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard acceptableStatuses.contains(http.statusCode) else {
            throw APIError.http(
                status: http.statusCode,
                code: decodeErrorCode(data),
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return (data, http.statusCode)
    }

    /// Pulls `error` out of an `{"error":"...","message":"..."}` body.
    private static func decodeErrorCode(_ data: Data) -> String {
        struct ErrBody: Decodable { let error: String? }
        if let decoded = try? jsonDecoder().decode(ErrBody.self, from: data),
           let code = decoded.error {
            return code
        }
        return ""
    }

    private static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        // We do not use .iso8601 keyDecoding here because most date fields come
        // back as strings we parse explicitly (mixed fractional/non-fractional);
        // structs keep dates as String and convert via parseISO8601 when needed.
        return d
    }

    // MARK: Codable response structs

    struct MeResponse: Decodable {
        let clerk_user_id: String
        let role: String
        let display_name: String?
        let avatar_url: String?
    }

    struct RequestTrialURLResponse: Decodable {
        let upload_url: String
        let upload_id: String
        let expires_in: Int
    }

    struct PostTrialResponse: Decodable {
        let trial_id: Int
        let status: String   // "created" | "exists"
    }

    struct InviteInfoResponse: Decodable {
        let observer_name: String
        let status: String
        let expires_at: String?
    }

    struct AcceptInviteResponse: Decodable {
        let relationship_id: Int
        let status: String
        let observer_name: String
    }

    struct ObserverEntry: Decodable, Identifiable {
        let relationship_id: Int
        let observer_id: String
        let display_name: String?
        let created_at: String?

        var id: Int { relationship_id }
    }

    struct ObserversResponse: Decodable {
        let observers: [ObserverEntry]
    }

    struct RevokeResponse: Decodable {
        let status: String
    }

    // MARK: Onboarding

    /// `POST /me/onboard {"role":...}`. Idempotent server-side. Returns the
    /// user row. Treats 200 as success; a 409 `role_conflict` surfaces as a
    /// thrown `.http` the caller can ignore/log.
    @discardableResult
    static func onboard(role: String) async throws -> MeResponse {
        let (value, _) = try await send(
            method: "POST",
            path: "me/onboard",
            body: ["role": role],
            acceptableStatuses: [200],
            decode: MeResponse.self
        )
        return value
    }

    // MARK: Invites (patient side)

    /// `GET /invites/<token>` — approval-screen data.
    static func inviteInfo(token: String) async throws -> InviteInfoResponse {
        let (value, _) = try await send(
            method: "GET",
            path: "invites/\(token)",
            decode: InviteInfoResponse.self
        )
        return value
    }

    /// `POST /invites/<token>/accept` — idempotent if already linked.
    @discardableResult
    static func acceptInvite(token: String) async throws -> AcceptInviteResponse {
        let (value, _) = try await send(
            method: "POST",
            path: "invites/\(token)/accept",
            decode: AcceptInviteResponse.self
        )
        return value
    }

    // MARK: Observers / relationships (patient "who can see my data")

    /// `GET /me/observers` — observers who can see me.
    static func observers() async throws -> [ObserverEntry] {
        let (value, _) = try await send(
            method: "GET",
            path: "me/observers",
            decode: ObserversResponse.self
        )
        return value.observers
    }

    /// `DELETE /relationships/<id>` — patient revokes an observer.
    @discardableResult
    static func revokeRelationship(id: Int) async throws -> RevokeResponse {
        let (value, _) = try await send(
            method: "DELETE",
            path: "relationships/\(id)",
            decode: RevokeResponse.self
        )
        return value
    }
}
