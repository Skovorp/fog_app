import SwiftUI

/// Full-screen loader shown between `.live` and `.results` while
/// `PostProcessor` drains the chunks the live scheduler skipped. A ring/pie
/// indicator counts down the remaining chunks; once the drainer finishes
/// it calls `onFinished()` (wired by `LiveRecordingScreen.stopAndSave`) to
/// flip the phase to `.results(Session)`.
struct ProcessingScreen: View {
    let processor: PostProcessor

    private var progress: Double {
        guard processor.total > 0 else { return 1 }
        return Double(processor.processed) / Double(processor.total)
    }

    var body: some View {
        ZStack {
            Color.lucheInk.ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    // Track
                    Circle()
                        .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    // Fill
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: progress)

                    VStack(spacing: 4) {
                        Text("\(remaining)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(value: Double(remaining)))
                            .animation(.easeOut(duration: 0.2), value: remaining)
                        Text(remaining == 1 ? "chunk left" : "chunks left")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .textCase(.uppercase)
                            .tracking(1.5)
                    }
                }
                .frame(width: 200, height: 200)

                VStack(spacing: 6) {
                    Text("Finishing scoring")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Filling in chunks skipped during recording.")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredOrientation(.portrait)
    }

    private var remaining: Int {
        Swift.max(0, processor.total - processor.processed)
    }
}
