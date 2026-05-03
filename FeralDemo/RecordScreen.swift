import SwiftUI

/// Idle screen: white background that matches the cover artwork. Cover image
/// on the left, app title, big black Start button, and a quieter "Previous
/// sessions" button on the right.
struct RecordScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationStack {
            ZStack {
                Color.white.ignoresSafeArea()

                HStack(spacing: 40) {
                    Image("Cover")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320, maxHeight: 320)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 24) {
                        Text("feral: parkinson's")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)

                        Button {
                            state.startRecording()
                        } label: {
                            Text("Start")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 220, height: 64)
                                .background(Color.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start recording")

                        NavigationLink {
                            SessionsScreen()
                        } label: {
                            Text("Previous sessions")
                                .font(.system(size: 17, weight: .medium, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(width: 220, height: 50)
                                .background(Color.black.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View previous sessions")
                    }
                }
                .padding(.horizontal, 48)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

#Preview("RecordScreen") {
    RecordScreen()
        .environment(AppState())
        .environment(SessionStore())
}
