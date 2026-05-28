import SwiftUI

/// "Data sharing" — single hub for cloud-sync consent + who-can-see-my-data.
/// Replaces the old "Who can see my data" / "Share data" split. Reached from
/// MenuScreen.
///
/// Two sections, both on one screen:
/// 1. **Cloud sync** — master on/off Toggle bound through `syncBinding` so
///    flipping OFF can be intercepted with a confirmation. ON enables
///    background-while-app-is-open uploads of every new recording + an
///    immediate backfill of any previously-unsynced trials. OFF stops future
///    uploads; the destructive "Delete uploaded videos" affordance is wired
///    but cloud deletion itself is not yet implemented (TODO).
/// 2. **Who can see my data** — the existing approved-observers list with
///    revoke flow (`GET /me/observers` / `DELETE /relationships/<id>`).
///    Revoke copy follows design §8.1: revocation is immediate for new views,
///    but a link opened in the last few minutes may still play briefly.
struct DataSharingScreen: View {
    @Environment(SessionStore.self) private var store

    private enum LoadState {
        case loading
        case loaded([APIClient.ObserverEntry])
        case error(String)
    }

    @State private var loadState: LoadState = .loading
    @State private var pendingRevoke: APIClient.ObserverEntry?
    @State private var revokingId: Int?
    @State private var actionError: String?

    /// Driven by `syncBinding`'s OFF intercept. While true, the alert is
    /// shown and the actual store toggle stays ON until the user confirms.
    @State private var showOffConfirm: Bool = false
    /// One-time enable explainer so the user understands ON means continuing
    /// consent for *all* future recordings + immediate backfill of past ones.
    @State private var showEnableConfirm: Bool = false

    var body: some View {
        mainContent
            .navigationTitle("Data sharing")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .task { await load() }
            .modifier(SyncConfirmAlerts(
                showEnable: $showEnableConfirm,
                showOff: $showOffConfirm,
                enableMessage: enableConfirmMessage,
                offMessage: offConfirmMessage,
                onEnable: { store.setSyncEnabled(true) },
                onTurnOff: { store.setSyncEnabled(false) },
                onDeleteAndOff: {
                    // TODO: call backend DELETE for every id in uploadedIDs once
                    // the per-trial delete endpoint exists; also clear those ids
                    // from `uploadedIDs` so a re-enable re-uploads them.
                    store.setSyncEnabled(false)
                }
            ))
            .alert("Revoke access?", isPresented: revokeAlertBinding) {
                Button("Cancel", role: .cancel) { pendingRevoke = nil }
                Button("Revoke", role: .destructive) {
                    if let entry = pendingRevoke { Task { await revoke(entry) } }
                    pendingRevoke = nil
                }
            } message: {
                Text(revokeMessage)
            }
            .alert("Couldn't revoke", isPresented: revokeErrorBinding) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
    }

    private var mainContent: some View {
        // The ScrollView has to be the direct content of the navigation
        // (not wrapped in a ZStack with a full-bleed background) so the
        // navigation bar can track its scroll offset. Without this the
        // large title collapses to inline on the first scroll-down and
        // never returns when the user scrolls back up.
        ScrollView {
            VStack(spacing: 20) {
                syncSection
                observersSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color.white.ignoresSafeArea())
    }

    private var revokeAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        )
    }

    private var revokeErrorBinding: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private var revokeMessage: String {
        // §8.1: don't claim instant total cutoff.
        let name = pendingRevoke?.display_name ?? "this observer"
        return "\(name) will immediately stop seeing new data. A video they opened in the last few minutes may still play briefly."
    }

    /// Pre-computed alert copy. Keeps the alert closures free of conditional
    /// `Text` builders that the Swift type-checker struggles to resolve
    /// inside the SwiftUI `Alert.message` builder.
    private var enableConfirmMessage: String {
        let pending = store.uploadableCount - store.syncedCount
        if pending > 0 {
            let plural = pending == 1 ? "" : "s"
            return "This and every future test will upload to secure storage while the app is open, so your care team can review them. \(pending) recorded video\(plural) will upload immediately."
        }
        return "Every future test will upload to secure storage while the app is open, so your care team can review it."
    }

    private var offConfirmMessage: String {
        let n = store.syncedCount
        let plural = n == 1 ? "" : "s"
        return "New tests will stop uploading. Your \(n) already-uploaded video\(plural) stay in the cloud unless you delete them."
    }

    // MARK: Cloud-sync section

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: syncBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync to the cloud")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.lucheInk)
                    Text("New tests upload automatically while the app is open, so your care team can review them.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.lucheInk.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.lucheInk)

            syncStatusLine
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lucheInk.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Intercepts the OFF transition so we can present a confirmation, and the
    /// ON transition so the user sees the one-time consent explainer. The
    /// Toggle visually snaps back to its bound value (`store.syncEnabled`)
    /// while the alert is up — that is the desired "doesn't change until you
    /// confirm" UX.
    private var syncBinding: Binding<Bool> {
        Binding(
            get: { store.syncEnabled },
            set: { newValue in
                if newValue {
                    showEnableConfirm = true
                } else {
                    showOffConfirm = true
                }
            }
        )
    }

    @ViewBuilder
    private var syncStatusLine: some View {
        if store.syncEnabled {
            let m = store.uploadableCount
            let n = store.syncedCount
            HStack(spacing: 8) {
                if store.isSyncing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.lucheInk)
                        .controlSize(.small)
                    Text("Syncing… \(n) of \(m) video\(m == 1 ? "" : "s")")
                } else if store.lastSyncFailed && n < m {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Couldn't sync — will retry next test")
                } else if m == 0 {
                    Image(systemName: "tray")
                        .foregroundStyle(.lucheInk.opacity(0.4))
                    Text("Nothing to sync yet")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(n) of \(m) video\(m == 1 ? "" : "s") synced")
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.lucheInk.opacity(0.7))
        }
    }

    // MARK: Observers section

    private var observersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who can see my data")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.lucheInk)
            Text("People you've approved can view your motor test results and play your recordings. Revoke anyone, anytime.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.lucheInk.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            observersContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var observersContent: some View {
        // Crossfade between phases so the loading → loaded swap doesn't
        // flash the list in. The spinner reserves at least a row-and-a-
        // half of height (`minHeight: 96`) so the surrounding ScrollView
        // doesn't jump when the rows materialize.
        Group {
            switch loadState {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView().progressViewStyle(.circular).tint(.lucheInk)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 96)
                .transition(.opacity)

            case .error(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.lucheInk)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
                .padding(.vertical, 24)
                .transition(.opacity)

            case .loaded(let observers):
                if observers.isEmpty {
                    observersEmpty
                        .transition(.opacity)
                } else {
                    VStack(spacing: 12) {
                        ForEach(observers) { observer in
                            observerRow(observer)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: loadStateKey)
    }

    /// Stable key for animating between phases (the associated `[Observer]`
    /// would otherwise change identity on every refresh and reset the fade).
    private var loadStateKey: Int {
        switch loadState {
        case .loading: return 0
        case .error:   return 1
        case .loaded(let list): return 2 + list.count
        }
    }

    private func observerRow(_ observer: APIClient.ObserverEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.lucheInk)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(observer.display_name ?? "Observer")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.lucheInk)
                if let created = observer.created_at,
                   let date = APIClient.parseISO8601(created) {
                    Text("Approved \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.lucheInk.opacity(0.5))
                }
            }

            Spacer(minLength: 0)

            if revokingId == observer.relationship_id {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.lucheInk)
                    .controlSize(.small)
            } else {
                Button {
                    pendingRevoke = observer
                } label: {
                    Text("Revoke")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lucheInk.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var observersEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No one has access")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
            Text("When you approve an invite from a doctor or family member, they'll show up here.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: Networking

    private func load() async {
        loadState = .loading
        do {
            let observers = try await APIClient.observers()
            loadState = .loaded(observers)
        } catch {
            loadState = .error(error.localizedDescription)
        }
    }

    private func revoke(_ observer: APIClient.ObserverEntry) async {
        revokingId = observer.relationship_id
        defer { revokingId = nil }
        do {
            _ = try await APIClient.revokeRelationship(id: observer.relationship_id)
            // Drop the revoked row locally without a full refetch.
            if case .loaded(var list) = loadState {
                list.removeAll { $0.relationship_id == observer.relationship_id }
                loadState = .loaded(list)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Two sync-toggle confirmation alerts factored out as a `ViewModifier` so the
/// main `body` doesn't pile up enough modifier closures to trip the SwiftUI
/// type-checker's expression-complexity guard.
private struct SyncConfirmAlerts: ViewModifier {
    @Binding var showEnable: Bool
    @Binding var showOff: Bool
    let enableMessage: String
    let offMessage: String
    let onEnable: () -> Void
    let onTurnOff: () -> Void
    let onDeleteAndOff: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Turn on cloud sync?", isPresented: $showEnable) {
                Button("Turn on sync", action: onEnable)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(enableMessage)
            }
            .alert("Turn off cloud sync?", isPresented: $showOff) {
                Button("Delete uploaded videos", role: .destructive, action: onDeleteAndOff)
                Button("Turn off, keep videos in cloud", action: onTurnOff)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(offMessage)
            }
    }
}

#Preview("Data sharing") {
    NavigationStack {
        DataSharingScreen()
            .environment(SessionStore())
    }
}
