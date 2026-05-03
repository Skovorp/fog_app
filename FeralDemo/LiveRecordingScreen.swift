import SwiftUI
import AVFoundation

/// Live recording screen: camera preview fills the whole landscape canvas,
/// the sliding score bar is overlaid edge-to-edge at the bottom, and a Stop
/// button sits in the top-right corner. Pinch on the preview to zoom in/out
/// like the iOS Camera app.
///
/// While the model is being loaded (`isReady == false`), a centered spinner +
/// "Preparing model…" overlay covers the black background — without it the
/// app appears frozen on first Start tap (model load is ~1–2 s).
struct LiveRecordingScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionStore.self) private var sessions
    @State private var camera = CameraSession()
    @State private var frameBuffer: FrameBuffer?
    @State private var inference: Inference?
    @State private var simTimer: Timer?
    @State private var baseZoom: CGFloat = 1.0
    @State private var currentZoom: CGFloat = 1.0
    @State private var startedAt: Date = Date()
    @State private var isReady: Bool = false
    @State private var sessionID: UUID = UUID()
    @State private var videoFilename: String?
    @State private var isStopping: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if targetEnvironment(simulator)
            LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .overlay(
                    Text("Simulator — synthetic frames")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                )
            #else
            CameraPreviewView(cameraSession: camera)
                .ignoresSafeArea()
                .gesture(zoomGesture)
                .opacity(isReady ? 1 : 0)
            #endif

            // Frame bar — edge-to-edge, ignores safe area on all sides
            VStack {
                Spacer()
                if let frameBuffer, isReady {
                    FrameBarView(frames: frameBuffer.frames)
                }
            }
            .ignoresSafeArea()

            // Stop button + zoom indicator — respect safe area
            VStack {
                HStack {
                    if frameBuffer != nil, isReady {
                        zoomBadge
                            .padding(.leading, 20)
                            .padding(.top, 16)
                    }
                    Spacer()
                    if isReady {
                        stopButton
                            .padding(.trailing, 20)
                            .padding(.top, 16)
                    }
                }
                Spacer()
            }

            if !isReady {
                loadingOverlay
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await startSession() }
        .onDisappear { stopSession() }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 18) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.4)
            Text("Preparing model…")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text("This takes a couple of seconds the first time.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(28)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var stopButton: some View {
        Button {
            guard !isStopping else { return }
            isStopping = true
            Task { @MainActor in
                await stopAndSave()
                appState.stopRecording()
            }
        } label: {
            HStack(spacing: 6) {
                if isStopping {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .controlSize(.small)
                }
                Text(isStopping ? "Saving…" : "Stop")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Color.red.opacity(0.9))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isStopping)
        .accessibilityLabel("Stop recording")
    }

    private var zoomBadge: some View {
        let display = currentZoom / max(camera.zoomDivisor, 0.0001)
        return Text(String(format: "%.1fx", display))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let proposed = baseZoom * value.magnification
                let clamped = min(max(proposed, camera.minZoomFactor), camera.maxZoomFactor)
                currentZoom = clamped
                camera.setZoom(clamped)
            }
            .onEnded { _ in
                baseZoom = currentZoom
            }
    }

    @MainActor
    private func startSession() async {
        // Allocate the session ID + matching video filename up front so the
        // AVAssetWriter can write directly to its final on-disk path. We only
        // hand a URL to the camera in the device build; the simulator path
        // doesn't capture real frames.
        sessionID = UUID()
        let filename = "\(sessionID.uuidString).mp4"
        videoFilename = filename

        let inf: Inference?
        do {
            inf = try await Task.detached { try Inference() }.value
        } catch {
            #if targetEnvironment(simulator)
            inf = nil
            #else
            appState.fail("Failed to load model: \(error.localizedDescription)")
            return
            #endif
        }
        let buf = FrameBuffer(inference: inf) { error in
            appState.fail("Inference failed: \(error.localizedDescription)")
        }
        self.inference = inf
        self.frameBuffer = buf
        self.startedAt = Date()

        #if targetEnvironment(simulator)
        videoFilename = nil  // simulator never produces a video file
        startSimulatorStream(into: buf)
        isReady = true
        #else
        let videoURL = VideoStore.fileURL(for: filename)
        await camera.start(videoURL: videoURL) { buffer in
            buf.append(buffer: buffer)
        }
        if case .failed(let msg) = camera.phase {
            appState.fail(msg)
            return
        }
        baseZoom = camera.zoomFactor
        currentZoom = camera.zoomFactor
        isReady = true
        #endif
    }

    /// Tap-Stop path: stop capture (await mp4 finalization), then persist.
    @MainActor
    private func stopAndSave() async {
        simTimer?.invalidate()
        simTimer = nil
        #if !targetEnvironment(simulator)
        await camera.stop()
        #endif
        saveCurrentSession()
    }

    /// onDisappear cleanup: best-effort, don't block.
    private func stopSession() {
        simTimer?.invalidate()
        simTimer = nil
        #if !targetEnvironment(simulator)
        Task { @MainActor in await camera.stop() }
        #endif
    }

    /// Snapshot the per-frame scores collected during this run and persist as
    /// a `Session`. With 50% chunk overlap, every frame except the first 32
    /// (only chunk 0 covers them) and the last <chunk-shift> (waiting on the
    /// next overlapping chunk) gets two predictions. We truncate the saved
    /// scores at the last frame with `scoreCount == 2` per the export rule.
    private func saveCurrentSession() {
        guard let frameBuffer else {
            cleanupOrphanVideo()
            return
        }
        let allFrames = frameBuffer.frames
        guard let lastTwoIdx = allFrames.lastIndex(where: { $0.scoreCount == 2 }) else {
            cleanupOrphanVideo()
            return
        }
        let scored = allFrames[0...lastTwoIdx].compactMap { $0.score }
        guard !scored.isEmpty else {
            cleanupOrphanVideo()
            return
        }
        let session = Session(
            id: sessionID,
            startedAt: startedAt,
            endedAt: Date(),
            scores: scored,
            device: DeviceInfo.current(),
            videoFilename: videoFilename
        )
        sessions.add(session)
    }

    /// If the recording was too short to score (no frame got 2 predictions),
    /// drop the orphan .mp4 — there's no Session pointing at it.
    private func cleanupOrphanVideo() {
        if let filename = videoFilename {
            VideoStore.delete(filename: filename)
        }
    }

    #if targetEnvironment(simulator)
    /// Synthetic frame stream for the simulator: appends a frame every ~42 ms
    /// and runs synthetic 64-frame chunks at 32-frame overlap so the simulator
    /// matches the on-device 50%-overlap pipeline.
    private func startSimulatorStream(into buf: FrameBuffer) {
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { _ in
            Task { @MainActor in
                buf.appendSynthetic()
                let n = buf.frames.count
                let size = FrameBuffer.chunkSize
                let shift = FrameBuffer.chunkShift
                if n >= size && (n - size) % shift == 0 {
                    let start = n - size
                    let base = Float.random(in: 0...1)
                    let scores: [Float] = (0..<size).map { _ in
                        max(0, min(1, base + Float.random(in: -0.25...0.25)))
                    }
                    buf.applySyntheticChunk(scores, start: start)
                }
            }
        }
    }
    #endif
}

#Preview("LiveRecording — sim") {
    LiveRecordingScreen()
        .environment(AppState())
        .environment(SessionStore())
}
