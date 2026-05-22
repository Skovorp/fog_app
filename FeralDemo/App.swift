import SwiftUI
import Observation
import AVFoundation
import ClerkKit

enum AppPhase: Equatable {
    case menu
    case instructions(Evaluation)
    case live(Evaluation)
    case results(Session)
    case error(message: String)
}

@MainActor
@Observable
final class AppState {
    var phase: AppPhase = .menu

    func select(_ evaluation: Evaluation) { phase = .instructions(evaluation) }
    func confirm(_ evaluation: Evaluation) { phase = .live(evaluation) }
    func finished(_ session: Session) { phase = .results(session) }
    func backToMenu() { phase = .menu }
    func fail(_ message: String) { phase = .error(message: message) }
    func reset() { phase = .menu }
}

// pk_test_ keys are publishable by design — safe to embed in the binary.
// Move to xcconfig when we add a prod key.
private let clerkPublishableKey = "pk_test_ZGlyZWN0LWhpcHBvLTM4LmNsZXJrLmFjY291bnRzLmRldiQ"

@main
struct FeralDemoApp: App {
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
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(Clerk.self) private var clerk

    var body: some View {
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
            case .results(let session):
                ResultsScreen(session: session)
            case .error(let message):
                ErrorScreen(message: message)
                    .preferredOrientation(.portrait)
            }
        }
    }
}

struct LoadingScreen: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.black)
        }
    }
}

struct ErrorScreen: View {
    @Environment(AppState.self) private var state
    let message: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
                        .foregroundStyle(.black)
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
