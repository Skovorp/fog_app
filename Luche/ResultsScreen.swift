import SwiftUI

/// Post-recording summary: headline metric, secondary stats, share-PDF button,
/// and Done. Portrait. Headline metric depends on which evaluation was run:
/// FoG headlines % FoG frames; everything else headlines the 0-4 UPDRS demo
/// score with a "research preview" caveat.
struct ResultsScreen: View {
    @Environment(AppState.self) private var state
    let session: Session

    @State private var pendingPDF: PDFItem?
    @State private var pdfError: String?
    @State private var isGenerating = false

    private var evaluation: Evaluation { session.effectiveEvaluation }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 28)

                Spacer(minLength: 16)

                headlineMetric
                    .padding(.horizontal, 24)

                Text("Demo score · research preview")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.lucheInk.opacity(0.4))
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .padding(.top, 8)

                Spacer(minLength: 16)

                statsRow
                    .padding(.horizontal, 24)

                Spacer()

                actions
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .alert("Couldn't generate PDF", isPresented: pdfErrorBinding) {
            Button("OK") { pdfError = nil }
        } message: {
            Text(pdfError ?? "")
        }
        .sheet(item: $pendingPDF) { item in
            ShareSheet(items: [item.url])
        }
        .preferredOrientation(.portrait)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(evaluation.displayName)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.lucheInk)
            Text(evaluation.updrsItem)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.45))
                .textCase(.uppercase)
                .tracking(1.2)
        }
    }

    @ViewBuilder
    private var headlineMetric: some View {
        if evaluation.headlinesFogPct {
            VStack(spacing: 6) {
                Text(String(format: "%.1f%%", session.fogPct))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.lucheInk)
                Text("of frames classified as freezing")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.lucheInk.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        } else {
            // Headline value scaled to the evaluation's display range.
            //   - Chair (0–1): show "0.42" alone.
            //   - Walking / Tapping (0–4): show "1.85 / 4" so the raw
            //     MDS-UPDRS scale is unambiguous.
            let upper = evaluation.scoreRange.upperBound
            let valueText: String = {
                if upper > 1 {
                    return String(format: "%.2f / %.0f", session.updrsScore, Double(upper))
                }
                return String(format: "%.2f", session.updrsScore)
            }()
            VStack(spacing: 6) {
                Text(valueText)
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.lucheInk)
                Text(session.updrsBand)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.lucheInk.opacity(0.7))
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            stat("Duration", value: durationString)
            divider
            stat("Frames", value: "\(session.totalFrames)")
            divider
            if evaluation.headlinesFogPct {
                stat("Avg score", value: String(format: "%.2f", session.avgProbability))
            } else {
                stat("Avg p", value: String(format: "%.2f", session.avgProbability))
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.lucheInk.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.lucheInk)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.5))
                .textCase(.uppercase)
                .tracking(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.lucheInk.opacity(0.08))
            .frame(width: 1, height: 32)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                generatePDF()
            } label: {
                HStack(spacing: 8) {
                    if isGenerating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(isGenerating ? "Generating…" : "Download PDF")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(Color.lucheInk)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Button {
                state.backToMenu()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.lucheInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.lucheInk.opacity(0.06))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var durationString: String {
        let total = Int(session.duration)
        let m = total / 60
        let s = total % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private var pdfErrorBinding: Binding<Bool> {
        Binding(
            get: { pdfError != nil },
            set: { if !$0 { pdfError = nil } }
        )
    }

    private func generatePDF() {
        guard !isGenerating else { return }
        isGenerating = true
        let snapshot = session
        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error>
            do {
                let url = try SessionPDF.generate(snapshot)
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isGenerating = false
                switch result {
                case .success(let url):
                    pendingPDF = PDFItem(url: url)
                case .failure(let error):
                    pdfError = error.localizedDescription
                }
            }
        }
    }
}

private struct PDFItem: Identifiable {
    let id = UUID()
    let url: URL
}
