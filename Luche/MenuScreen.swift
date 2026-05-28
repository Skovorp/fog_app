import ClerkKitUI
import SwiftUI

/// Portrait menu: 5 evaluation buttons stacked vertically. Replaces the old
/// landscape RecordScreen. "Previous sessions" + Clerk's UserButton stay on
/// the top toolbar.
struct MenuScreen: View {
    @Environment(AppState.self) private var state
    @Environment(SessionStore.self) private var sessions

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

                    // In-app upload banner. Uploads are tied to the app being
                    // open (no iOS background-transfer infra) — warn the user
                    // not to close the app while a sync is running so they
                    // don't have to wait for the next launch to resume.
                    if sessions.isSyncing {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .controlSize(.small)
                            Text("Uploading your data… please keep the app open")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.lucheInk)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .transition(.opacity)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Uploading your data. Please keep the app open.")
                    }

                    // Title block.
                    VStack(spacing: 6) {
                        Text("Luche")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.lucheInk)
                        Text("Choose a test")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.lucheInk.opacity(0.55))
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
                            SessionsScreen()
                        } label: {
                            Text("Previous sessions")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.lucheInk)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.lucheInk.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View previous sessions")

                        NavigationLink {
                            DataSharingScreen()
                        } label: {
                            Text("Data sharing")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.lucheInk)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.lucheInk.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Data sharing")
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
                .background(Color.lucheInk)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(evaluation.displayName)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.lucheInk)
                Text(evaluation.updrsItem)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.lucheInk.opacity(0.5))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.lucheInk.opacity(0.35))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lucheInk.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview("Menu") {
    MenuScreen()
        .environment(AppState())
        .environment(SessionStore())
}
