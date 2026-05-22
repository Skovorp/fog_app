import SwiftUI
import UIKit

/// Pre-recording instruction screen. Landscape-preferred so it flows directly
/// into the (also-landscape) recording screen with no extra rotation. The
/// menu→instruction rotation happens up-front; back-to-menu rotates back via
/// `AppState.backToMenu` which pre-requests portrait before swapping phase.
struct InstructionScreen: View {
    @Environment(AppState.self) private var state
    let evaluation: Evaluation

    var body: some View {
        GeometryReader { proxy in
            let isPortrait = proxy.size.height > proxy.size.width

            ZStack {
                Color.white.ignoresSafeArea()

                if isPortrait {
                    rotateHint
                } else {
                    landscapeBody
                }
            }
            .overlay(alignment: .topLeading) {
                backButton
                    .padding(.leading, 18)
                    .padding(.top, 14)
            }
        }
        .preferredOrientation(.landscape)
    }

    private var landscapeBody: some View {
        // Static landscape layout: video left, title + bullets + Continue right.
        // No scrolling — sized so everything fits at iPhone Pro Max landscape
        // height (~440pt).
        HStack(alignment: .center, spacing: 24) {
            iconArtwork
                .frame(width: 340)

            VStack(alignment: .leading, spacing: 14) {
                Text(evaluation.instructionTitle)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(evaluation.instructionSteps, id: \.self) { step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("•")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.black.opacity(0.7))
                                .frame(width: 12, alignment: .leading)
                            Text(step)
                                .font(.system(size: 19, weight: .regular, design: .rounded))
                                .foregroundStyle(.black.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Button {
                    state.confirm(evaluation)
                } label: {
                    Text("Continue")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 300)
                        .frame(height: 52)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Continue to recording")
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    /// Per-evaluation hero artwork in the left column. Resolution order:
    ///   1. Looping mp4 in the bundle (preferred — see `Evaluation.demoVideoResource`)
    ///   2. SF Symbol fallback
    ///
    /// LoopingVideo is a `UIViewRepresentable` with no intrinsic content size,
    /// so `.aspectRatio(16/9, .fit)` applied directly to it doesn't constrain
    /// it — it just fills whatever the column gives it. The fix: anchor the
    /// layout with a `Rectangle` that has the aspect ratio, then overlay the
    /// video into it.
    @ViewBuilder
    private var iconArtwork: some View {
        if let resource = evaluation.demoVideoResource,
           let url = Bundle.main.url(forResource: resource, withExtension: "mp4") {
            Rectangle()
                .fill(Color.clear)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxHeight: 260)
                .overlay(LoopingVideo(url: url))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityLabel("\(evaluation.displayName) demonstration video")
        } else {
            Image(systemName: evaluation.symbolName)
                .font(.system(size: 140, weight: .light))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: 260)
        }
    }

    // MARK: Portrait fallback (rotate hint)

    private var rotateHint: some View {
        VStack(spacing: 18) {
            Image(systemName: "rotate.right")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.black.opacity(0.75))
            Text("Rotate to landscape")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
            Text("Turn the phone sideways to read the test instructions.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var backButton: some View {
        Button {
            state.backToMenu()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to menu")
    }
}

#Preview("Instruction — Walking") {
    InstructionScreen(evaluation: .gait)
        .environment(AppState())
}

#Preview("Instruction — FoG", traits: .landscapeLeft) {
    InstructionScreen(evaluation: .freezingOfGait)
        .environment(AppState())
}

#Preview("Instruction — Finger Tapping", traits: .landscapeLeft) {
    InstructionScreen(evaluation: .fingerTapping)
        .environment(AppState())
}

#Preview("Instruction — Chair", traits: .landscapeLeft) {
    InstructionScreen(evaluation: .arisingFromChair)
        .environment(AppState())
}
