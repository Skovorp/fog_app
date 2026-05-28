import SwiftUI
import UIKit
import Observation
import AVFoundation
import ClerkKit

extension Color {
    static let lucheInk = Color(red: 0x08 / 255.0, green: 0x06 / 255.0, blue: 0x16 / 255.0)
}

extension ShapeStyle where Self == Color {
    static var lucheInk: Color { .lucheInk }
}

extension UIColor {
    static let lucheInk = UIColor(red: 0x08 / 255.0, green: 0x06 / 255.0, blue: 0x16 / 255.0, alpha: 1.0)
}

enum AppPhase: Equatable {
    case menu
    case instructions(Evaluation)
    case live(Evaluation)
    /// Post-session "fill in skipped chunks" phase. The PostProcessor owns
    /// FrameBuffer + Inference + the mp4 URL so they survive the screen
    /// transition out of `.live(_)`.
    case processing(PostProcessor)
    case results(Session)
    case error(message: String)
}

@MainActor
@Observable
final class AppState {
    var phase: AppPhase = .menu

    func select(_ evaluation: Evaluation) { phase = .instructions(evaluation) }
    func confirm(_ evaluation: Evaluation) { phase = .live(evaluation) }
    func processing(_ processor: PostProcessor) { phase = .processing(processor) }
    func finished(_ session: Session) { phase = .results(session) }
    func backToMenu() { phase = .menu }
    func fail(_ message: String) { phase = .error(message: message) }
    func reset() { phase = .menu }
}

// pk_test_ keys are publishable by design — safe to embed in the binary.
// Move to xcconfig when we add a prod key.
private let clerkPublishableKey = "pk_test_ZGlyZWN0LWhpcHBvLTM4LmNsZXJrLmFjY291bnRzLmRldiQ"

@main
struct LucheApp: App {
    @State private var state = AppState()
    @State private var sessions = SessionStore()

    init() {
        // .ambient + .mixWithOthers tells iOS we don't claim the audio session
        // for our (silent) instruction-video player or camera-capture session.
        // Without this, AVQueuePlayer's default behavior interrupts whatever
        // the user is already listening to (Spotify, podcasts, etc.) the
        // moment any of our screens come up.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])

        Clerk.configure(publishableKey: clerkPublishableKey)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .environment(sessions)
                .environment(Clerk.shared)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                // App-wide light mode. The Luche UI hard-codes a white /
                // `lucheInk` palette and a few screens (SessionsScreen,
                // results cards) lean on system semantic colours like
                // `secondarySystemBackground` + `.primary` / `.secondary`
                // text — pinning to `.light` keeps those reading correctly
                // on phones in system Dark Mode.
                .preferredColorScheme(.light)
        }
    }
}

/// Parses `luche://invite?token=<token>` and returns the token, if present.
func parseInviteToken(from url: URL) -> String? {
    guard url.scheme?.lowercased() == "luche",
          url.host?.lowercased() == "invite" else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let token = components?.queryItems?.first(where: { $0.name == "token" })?.value
    guard let token, !token.isEmpty else { return nil }
    return token
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(Clerk.self) private var clerk
    @Environment(SessionStore.self) private var sessions

    /// Token from an incoming `luche://invite?token=` deep link. While
    /// non-nil and the user is signed in, the approval sheet is presented. If a
    /// link arrives while signed out, it stays stashed here until sign-in
    /// completes (the .onChange below re-presents it).
    @State private var pendingInviteToken: String?
    @State private var showInviteApproval = false

    /// The Clerk user id we last successfully onboarded. Persisted so a relaunch
    /// by the same user doesn't re-hit the server, but keyed by user id (not a
    /// global install flag) so a *different* Clerk user signing in on the same
    /// device re-onboards — otherwise the new user's `users` row is never
    /// created and every upload/accept FK-fails server-side.
    @AppStorage("lastOnboardedUserID") private var lastOnboardedUserID = ""

    /// In-flight onboarding task for the current user, so dependent flows (e.g.
    /// invite approval) can `await` it and guarantee the patient row exists
    /// before they call an endpoint with a FK on it.
    @State private var onboardingTask: Task<Void, Never>?

    var body: some View {
        rootContent
            .onOpenURL { url in
                if let token = parseInviteToken(from: url) {
                    pendingInviteToken = token
                    // Only present immediately if signed in; otherwise the
                    // onChange(clerk.user) hook resumes it after auth.
                    if clerk.user != nil {
                        showInviteApproval = true
                    }
                }
            }
            .onChange(of: clerk.user?.id) { _, newUserId in
                guard newUserId != nil else {
                    // Signed out — clear any in-flight onboarding so the next
                    // user starts clean.
                    onboardingTask = nil
                    return
                }
                // Kick onboarding first so its task exists before we present
                // the approval sheet (which awaits it).
                onboardIfNeeded()
                // Launch catch-up for an already-onboarded user signing in
                // (onboardIfNeeded returns early when nothing to do; without
                // this call, sync would only start on the next `.onAppear`).
                syncIfOnboarded()
                // Resume a stashed invite once the user is signed in.
                if pendingInviteToken != nil {
                    showInviteApproval = true
                }
            }
            .onAppear {
                if clerk.user != nil {
                    onboardIfNeeded()
                    // Launch catch-up: if this user is already onboarded from a
                    // prior session and sync is on, drain anything that didn't
                    // finish uploading last time. `triggerSync()` self-guards
                    // on `syncEnabled`, so it's a no-op when sync is off.
                    syncIfOnboarded()
                }
            }
            .fullScreenCover(isPresented: $showInviteApproval) {
                if let token = pendingInviteToken {
                    InviteApprovalScreen(token: token, ensureOnboarded: { await ensureOnboarded() }) {
                        showInviteApproval = false
                        pendingInviteToken = nil
                    }
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if !clerk.isLoaded {
            LoadingScreen()
        } else if clerk.user == nil {
            AuthScreen()
                .preferredOrientation(.portrait)
        } else {
            switch state.phase {
            case .menu:
                MenuScreen()
            case .instructions(let evaluation):
                InstructionScreen(evaluation: evaluation)
            case .live(let evaluation):
                LiveRecordingScreen(evaluation: evaluation)
            case .processing(let processor):
                ProcessingScreen(processor: processor)
            case .results(let session):
                ResultsScreen(session: session)
            case .error(let message):
                ErrorScreen(message: message)
                    .preferredOrientation(.portrait)
            }
        }
    }

    /// Fire-and-forget patient onboarding for the *current* Clerk user. Skips
    /// the network call when this user id is already onboarded; otherwise starts
    /// an onboarding task (stored so dependent flows can await it). On failure
    /// `lastOnboardedUserID` is left unchanged so the next launch retries.
    private func onboardIfNeeded() {
        guard let userId = clerk.user?.id else { return }
        // Already onboarded this exact user and no task is needed.
        if lastOnboardedUserID == userId, onboardingTask == nil { return }
        // A task is already running for the current user — reuse it.
        if onboardingTask != nil, lastOnboardedUserID != userId { return }
        startOnboarding(for: userId)
    }

    private func startOnboarding(for userId: String) {
        // Don't start a second concurrent task for the same user.
        if onboardingTask != nil { return }
        onboardingTask = Task {
            var onboarded = false
            do {
                _ = try await APIClient.onboard(role: "patient")
                lastOnboardedUserID = userId
                onboarded = true
            } catch {
                // 409 role_conflict (already an observer elsewhere) or a
                // network blip — log and retry next launch / on next demand.
                print("[onboard] failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                onboardingTask = nil
                // Kick a sync drain only after the patient row exists; any
                // earlier and the /trials POST FK-fails silently.
                if onboarded { sessions.triggerSync() }
            }
        }
    }

    /// Trigger a sync drain only if onboarding for the current Clerk user has
    /// already succeeded in a prior session — guarantees the patient row exists
    /// before we POST /trials. `triggerSync()` itself is a no-op when
    /// `syncEnabled` is false.
    private func syncIfOnboarded() {
        guard let uid = clerk.user?.id, lastOnboardedUserID == uid else { return }
        sessions.triggerSync()
    }

    /// Awaitable onboarding gate for FK-dependent flows (invite accept). Ensures
    /// the current user's `users` row exists before returning. If onboarding
    /// already succeeded this session, returns immediately; if a task is
    /// in-flight, awaits it; otherwise starts one and awaits it (one retry).
    private func ensureOnboarded() async {
        guard let userId = clerk.user?.id else { return }
        if lastOnboardedUserID == userId { return }
        if onboardingTask == nil { startOnboarding(for: userId) }
        await onboardingTask?.value
    }
}

struct LoadingScreen: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.lucheInk)
        }
    }
}

struct ErrorScreen: View {
    @Environment(AppState.self) private var state
    let message: String

    var body: some View {
        ZStack {
            Color.lucheInk.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Something went wrong")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button { state.reset() } label: {
                    Text("Try again")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.lucheInk)
                        .frame(width: 220, height: 52)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview("Root — menu") {
    RootView()
        .environment(AppState())
        .environment(SessionStore())
}
