import SwiftUI

/// Patient-facing approval screen for an observer invite deep link
/// (`luche://invite?token=<token>`).
///
/// On appear it fetches `GET /invites/<token>` to learn the observer's name +
/// invite validity, then offers Approve (`POST /invites/<token>/accept`) /
/// Decline. Renders the contract's error codes (`invite_not_found`,
/// `expired`/`revoked`/`cap_reached`).
///
/// Portrait, matches the ResultsScreen visual language.
struct InviteApprovalScreen: View {
    let token: String
    /// Awaits patient onboarding so the patient `users` row exists before we
    /// `POST /invites/<token>/accept` (the accept upserts a `relationships` row
    /// with a FK on the patient id). Returns once onboarding has completed (or
    /// re-attempted once). Supplied by `RootView`.
    let ensureOnboarded: () async -> Void
    /// Called when the screen should be dismissed (decline, done, or after a
    /// successful approval the user acknowledges).
    let onDismiss: () -> Void

    private enum LoadState: Equatable {
        case loading
        case loaded(observerName: String)
        case approved(observerName: String)
        case error(message: String)
    }

    @State private var loadState: LoadState = .loading
    @State private var isApproving = false
    /// False until onboarding completes — gates the Approve button so the
    /// accept can never race ahead of the patient row being created.
    @State private var isOnboarded = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                switch loadState {
                case .loading:
                    loadingView
                case .loaded(let name):
                    approvalView(observerName: name)
                case .approved(let name):
                    approvedView(observerName: name)
                case .error(let message):
                    errorView(message: message)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .task {
            // Wait for the patient row to exist before the user can Approve.
            // Runs in parallel with the invite-info fetch; both must finish.
            async let onboarded: Void = ensureOnboarded()
            await load()
            await onboarded
            isOnboarded = true
        }
        .preferredOrientation(.portrait)
    }

    // MARK: States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.lucheInk)
            Text("Loading invite…")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private func approvalView(observerName: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.lucheInk)
                .padding(.bottom, 24)

            Text(observerName)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.lucheInk)
                .multilineTextAlignment(.center)

            Text("wants to view your motor test results")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 12)

            Text("If you approve, they'll be able to see your recorded tests and play the videos. You can revoke access anytime from \u{201C}Who can see my data.\u{201D}")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.horizontal, 8)

            Spacer(minLength: 32)

            VStack(spacing: 10) {
                Button {
                    Task { await approve() }
                } label: {
                    HStack(spacing: 8) {
                        if isApproving || !isOnboarded {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .controlSize(.small)
                        }
                        Text(isApproving ? "Approving…" : (isOnboarded ? "Approve" : "Preparing…"))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color.lucheInk.opacity(isOnboarded ? 1 : 0.6))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                // Disabled until the patient row exists — prevents the accept
                // from racing onboarding (FK failure otherwise).
                .disabled(isApproving || !isOnboarded)

                Button {
                    onDismiss()
                } label: {
                    Text("Decline")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.lucheInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.lucheInk.opacity(0.06))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isApproving)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func approvedView(observerName: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.lucheInk)
                .padding(.bottom, 20)

            Text("Access granted")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.lucheInk)

            Text("\(observerName) can now view your motor test results.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 12)

            Spacer(minLength: 32)

            Button { onDismiss() } label: {
                Text("Done")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color.lucheInk)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.lucheInk.opacity(0.7))
                .padding(.bottom, 20)

            Text("Invite unavailable")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.lucheInk)

            Text(message)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 12)

            Spacer(minLength: 32)

            Button { onDismiss() } label: {
                Text("Close")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.lucheInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.lucheInk.opacity(0.06))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Networking

    private func load() async {
        do {
            let info = try await APIClient.inviteInfo(token: token)
            // The server returns 410 for expired/revoked/cap; a 200 with a
            // non-active status is defensively mapped too.
            if info.status.lowercased() != "active" {
                loadState = .error(message: message(forCode: info.status))
                return
            }
            loadState = .loaded(observerName: info.observer_name)
        } catch let err as APIClient.APIError {
            loadState = .error(message: messageFor(err))
        } catch {
            loadState = .error(message: error.localizedDescription)
        }
    }

    private func approve() async {
        guard !isApproving else { return }
        isApproving = true
        defer { isApproving = false }
        // Belt-and-suspenders: even though the button is gated on `isOnboarded`,
        // await onboarding once more before accept so the patient row is
        // guaranteed present (invariant: patient exists before accept).
        await ensureOnboarded()
        isOnboarded = true
        do {
            let result = try await APIClient.acceptInvite(token: token)
            loadState = .approved(observerName: result.observer_name)
        } catch let err as APIClient.APIError {
            loadState = .error(message: messageFor(err))
        } catch {
            loadState = .error(message: error.localizedDescription)
        }
    }

    /// Maps an APIError to patient-facing copy, branching on the machine code.
    private func messageFor(_ err: APIClient.APIError) -> String {
        if let code = err.machineCode {
            return message(forCode: code)
        }
        if err.statusCode == 404 {
            return message(forCode: "invite_not_found")
        }
        return err.localizedDescription
    }

    private func message(forCode code: String) -> String {
        switch code.lowercased() {
        case "invite_not_found":
            return "This invite link isn't valid. Ask your observer to send a new one."
        case "expired":
            return "This invite has expired. Ask your observer to send a new link."
        case "revoked":
            return "This invite was revoked by the observer."
        case "cap_reached":
            return "This invite has reached its limit. Ask your observer for a new link."
        default:
            return "This invite can't be used right now. Ask your observer to send a new link."
        }
    }
}

#Preview("Invite approval") {
    InviteApprovalScreen(token: "demo-token", ensureOnboarded: { }) { }
}
