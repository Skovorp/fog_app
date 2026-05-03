import AVKit
import SwiftUI
import UIKit

struct SessionsScreen: View {
    @Environment(SessionStore.self) private var store
    @State private var pendingExport: ExportItem?
    @State private var exportError: String?
    @State private var exportingIDs: Set<UUID> = []
    @State private var pendingDelete: Session?
    @State private var showingClearAllConfirm = false
    @State private var showingExportAllDialog = false
    @State private var isExportingAll = false
    @State private var playingVideo: PlayingVideo?
    @AppStorage("skipDeleteConfirmation") private var skipDeleteConfirmation = false
    @AppStorage("sessionsTapHintSeen") private var tapHintSeen = false

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24),
    ]

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    if !tapHintSeen {
                        tapHintBanner
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    LazyVGrid(columns: columns, alignment: .center, spacing: 20) {
                        ForEach(store.sessions) { session in
                            SessionCard(
                                session: session,
                                isExporting: exportingIDs.contains(session.id),
                                hasVideo: VideoStore.existingURL(for: session) != nil,
                                videoSizeBytes: VideoStore.fileSizeBytes(for: session)
                            ) {
                                export(session)
                            } onDelete: {
                                requestDelete(session)
                            } onTap: {
                                playSession(session)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, tapHintSeen ? 8 : 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Previous sessions")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !store.sessions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showingExportAllDialog = true
                        } label: {
                            if isExportingAll {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Exporting…")
                                }
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                            } else {
                                Text("Export all")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                            }
                        }
                        .disabled(isExportingAll)

                        Button(role: .destructive) {
                            showingClearAllConfirm = true
                        } label: {
                            Text("Clear all")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .alert(
            "Export all sessions",
            isPresented: $showingExportAllDialog
        ) {
            Button("Human-readable PDF") { exportAll(.pdf) }
            Button("Machine-readable JSON") { exportAll(.json) }
            Button("Videos (ZIP)") { exportAll(.videos) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Combine all \(store.sessions.count) sessions into one file.")
        }
        .sheet(item: $pendingExport) { item in
            ShareSheet(items: [item.url])
        }
        .fullScreenCover(item: $playingVideo) { item in
            SessionVideoPlayer(url: item.url) {
                playingVideo = nil
            }
        }
        .alert("Export failed", isPresented: errorBinding, actions: {
            Button("OK") { exportError = nil }
        }, message: {
            Text(exportError ?? "")
        })
        .alert("Delete this session?", isPresented: deleteAlertBinding, presenting: pendingDelete) { session in
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                store.delete(session)
                pendingDelete = nil
            }
            Button("Delete & don't ask again", role: .destructive) {
                skipDeleteConfirmation = true
                store.delete(session)
                pendingDelete = nil
            }
        } message: { session in
            Text("\"\(session.displayTitle)\" — \(session.totalFrames) frames will be permanently removed.")
        }
        .alert("Clear all sessions?", isPresented: $showingClearAllConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Clear all", role: .destructive) {
                store.clear()
            }
        } message: {
            Text("All \(store.sessions.count) sessions will be permanently removed. This can't be undone.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func requestDelete(_ session: Session) {
        if skipDeleteConfirmation {
            store.delete(session)
        } else {
            pendingDelete = session
        }
    }

    private enum ExportAllFormat { case pdf, json, videos }

    private func exportAll(_ format: ExportAllFormat) {
        guard !isExportingAll else { return }
        isExportingAll = true
        let snapshot = store.sessions
        let fallbackDevice = DeviceInfo.current()  // captured on main
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
                isExportingAll = false
                switch result {
                case .success(let url):
                    pendingExport = ExportItem(url: url)
                case .failure(let error):
                    exportError = error.localizedDescription
                }
            }
        }
    }

    // MARK: First-visit hint

    private var tapHintBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Tap a card to watch the session video")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button {
                withAnimation { tapHintSeen = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Video playback

    private func playSession(_ session: Session) {
        guard let url = VideoStore.existingURL(for: session) else { return }
        playingVideo = PlayingVideo(id: session.id, url: url)
        // Tapping any card implicitly dismisses the hint.
        if !tapHintSeen { tapHintSeen = true }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
            Text("Hit Start on the home screen to record one.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func export(_ session: Session) {
        guard !exportingIDs.contains(session.id) else { return }
        exportingIDs.insert(session.id)
        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error>
            do {
                let url = try SessionPDF.generate(session)
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                exportingIDs.remove(session.id)
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

private struct PlayingVideo: Identifiable {
    let id: UUID
    let url: URL
}

private struct SessionCard: View {
    let session: Session
    let isExporting: Bool
    let hasVideo: Bool
    let videoSizeBytes: Int64?
    let onExport: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tappable header → opens video player when one is available.
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayTitle)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(session.timestampString)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        statChip(icon: "film.stack",
                                 text: "\(session.totalFrames) frames")
                        statChip(icon: session.fogCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                 text: String(format: "%.1f%% fog", session.fogPct),
                                 tint: session.fogCount == 0 ? .green : .red)
                        if let bytes = videoSizeBytes {
                            statChip(icon: "video", text: VideoStore.formatBytes(bytes))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasVideo)

            HStack(spacing: 10) {
                Button(action: onExport) {
                    exportButtonContent
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isExporting)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete session")
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var exportButtonContent: some View {
        if isExporting {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .controlSize(.small)
                Text("Generating…")
            }
        } else {
            Label("Export PDF", systemImage: "square.and.arrow.up")
        }
    }

    private func statChip(icon: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
        }
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SessionVideoPlayer: View {
    let url: URL
    let onDismiss: () -> Void
    @State private var player: AVPlayer

    init(url: URL, onDismiss: @escaping () -> Void) {
        self.url = url
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .onAppear { player.play() }
                .onDisappear { player.pause() }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .padding(.trailing, 20)
                }
                Spacer()
            }
        }
    }
}
