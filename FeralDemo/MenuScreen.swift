import ClerkKitUI
import SwiftUI

/// Portrait menu: 5 evaluation buttons stacked vertically. Replaces the old
/// landscape RecordScreen. "Previous sessions" + Clerk's UserButton stay on
/// the top toolbar.
struct MenuScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationStack {
            ZStack {
                Color.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top bar — account avatar only.
                    HStack {
                        Spacer()
                        UserButton()
                            .frame(width: 36, height: 36)
                            .accessibilityLabel("Account")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)

                    // Title block.
                    VStack(spacing: 6) {
                        Text("feral: parkinson's")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                        Text("Choose a test")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                    // Evaluation buttons.
                    VStack(spacing: 14) {
                        ForEach(Evaluation.allCases) { evaluation in
                            Button {
                                state.select(evaluation)
                            } label: {
                                evaluationRow(evaluation)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Start \(evaluation.displayName) test")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                    Spacer()

                    VStack(spacing: 12) {
                        NavigationLink {
                            ShareDataScreen()
                        } label: {
                            Text("Share data")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.black.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share data")

                        NavigationLink {
                            SessionsScreen()
                        } label: {
                            Text("Previous sessions")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.black.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View previous sessions")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredOrientation(.portrait)
    }

    private func evaluationRow(_ evaluation: Evaluation) -> some View {
        HStack(spacing: 16) {
            Image(systemName: evaluation.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(evaluation.displayName)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.black)
                Text(evaluation.updrsItem)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.black.opacity(0.5))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black.opacity(0.35))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview("Menu") {
    MenuScreen()
        .environment(AppState())
        .environment(SessionStore())
}
