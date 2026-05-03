import SwiftUI
import Observation

enum AppPhase {
    case idle
    case recording
    case error(message: String)
}

@MainActor
@Observable
final class AppState {
    var phase: AppPhase = .idle

    func startRecording() { phase = .recording }
    func stopRecording() { phase = .idle }
    func fail(_ message: String) { phase = .error(message: message) }
    func reset() { phase = .idle }
}

@main
struct FeralDemoApp: App {
    @State private var state = AppState()
    @State private var sessions = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .environment(sessions)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        switch state.phase {
        case .idle:
            RecordScreen()
        case .recording:
            LiveRecordingScreen()
        case .error(let message):
            ErrorScreen(message: message)
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

#Preview("Root — idle") {
    RootView()
        .environment(AppState())
        .environment(SessionStore())
}
