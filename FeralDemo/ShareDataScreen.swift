import SwiftUI

/// Bulk export + research data-sharing surface. Reached from the Menu screen.
/// Holds the three export-all formats (PDF / JSON / Videos ZIP) and the
/// "Share data with developers" action that used to live on ResultsScreen.
struct ShareDataScreen: View {
    @Environment(SessionStore.self) private var store

    @State private var pendingExport: ExportItem?
    @State private var exportError: String?
    @State private var isExporting = false
    @State private var showShareConsentAlert = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)
                    .padding(.horizontal, 24)

                Spacer(minLength: 8)

                if store.sessions.isEmpty {
                    emptyState
                } else {
                    buttons
                        .padding(.horizontal, 24)
                }

                Spacer()
            }
        }
        .navigationTitle("Share data")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.white, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .sheet(item: $pendingExport) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Export failed", isPresented: errorBinding, actions: {
            Button("OK") { exportError = nil }
        }, message: {
            Text(exportError ?? "")
        })
        .alert("Consent forms required", isPresented: $showShareConsentAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You haven't signed all the data-sharing forms yet. Please talk to your doctor and sign all the forms before sharing your session data.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bundle all \(store.sessions.count) session\(store.sessions.count == 1 ? "" : "s") into one file to download or share with your specialist.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.black.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            exportButton(
                icon: "doc.richtext",
                title: "Human-readable PDF",
                subtitle: "Charts + table of contents"
            ) {
                exportAll(.pdf)
            }

            exportButton(
                icon: "curlybraces",
                title: "Machine-readable JSON",
                subtitle: "Per-frame predictions + metadata"
            ) {
                exportAll(.json)
            }

            exportButton(
                icon: "film",
                title: "Videos (ZIP)",
                subtitle: "All recorded clips, one archive"
            ) {
                exportAll(.videos)
            }

            // Separated visually from the export trio — this one goes off-device.
            Divider()
                .padding(.vertical, 4)

            Button {
                showShareConsentAlert = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share data with your doctor")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.black)
                        Text("Send sessions to your care team")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(.black.opacity(0.55))
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.35))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share session data with your doctor")
        }
        .padding(.top, 12)
    }

    private func exportButton(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.black.opacity(0.55))
                }

                Spacer(minLength: 0)

                if isExporting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.black)
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isExporting)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
            Text("Record a test on the home screen to start collecting data.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private enum ExportAllFormat { case pdf, json, videos }

    private func exportAll(_ format: ExportAllFormat) {
        guard !isExporting else { return }
        isExporting = true
        let snapshot = store.sessions
        let fallbackDevice = DeviceInfo.current()
        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error>
            do {
                let url: URL
                switch format {
                case .pdf:    url = try SessionExport.generateAllPDF(snapshot)
                case .json:   url = try SessionExport.generateAllJSON(snapshot, fallbackDevice: fallbackDevice)
                case .videos: url = try SessionExport.generateAllVideosZIP(snapshot)
                }
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isExporting = false
                switch result {
                case .success(let url):
                    pendingExport = ExportItem(url: url)
                case .failure(let error):
                    exportError = error.localizedDescription
                }
            }
        }
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

#Preview("ShareDataScreen") {
    NavigationStack {
        ShareDataScreen()
            .environment(SessionStore())
    }
}
