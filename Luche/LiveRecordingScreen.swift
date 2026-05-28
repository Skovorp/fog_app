import SwiftUI
import AVFoundation

/// Live recording screen. Three substates:
///   1. **Loading** — camera + model coming up; centered spinner overlay.
///   2. **Preview** — camera preview + score bar are live. Inference runs so
///      the user can see the model working before they commit. A giant Start
///      button sits dead-centre. Nothing is being saved.
///   3. **Recording** — user tapped Start. The .mp4 begins, the index of the
///      first "saved" frame is captured, and Stop appears top-right. The score
///      bar keeps flowing without resetting — visual continuity matters.
///
/// "Save from Start to Stop":
///   - The .mp4 contains only Start→Stop frames (CameraSession.beginRecording
///     is called only on the Start tap).
///   - On Stop we slice `frameBuffer.frames[recordingStartFrameIndex...]`
///     before writing the Session so preview-window scores aren't persisted.
struct LiveRecordingScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(SessionStore.self) private var sessions
    let evaluation: Evaluation

    @State private var camera = CameraSession()
    @State private var frameBuffer: FrameBuffer?
    @State private var inference: Inference?
    @State private var simTimer: Timer?
    @State private var baseZoom: CGFloat = 1.0
    @State private var currentZoom: CGFloat = 1.0
    @State private var startedAt: Date = Date()
    @State private var isModelLoaded: Bool = false
    @State private var isCameraReady: Bool = false
    @State private var isRecording: Bool = false
    @State private var sessionID: UUID = UUID()
    @State private var videoFilename: String?
    @State private var isStopping: Bool = false
    /// Index in `frameBuffer.frames` of the first frame that counts toward the
    /// saved Session. Frames before this are preview only.
    @State private var recordingStartFrameIndex: Int = 0

    private var isReady: Bool { isModelLoaded && isCameraReady }

    var body: some View {
        ZStack {
            Color.lucheInk.ignoresSafeArea()

            #if targetEnvironment(simulator)
            LinearGradient(colors: [.indigo, .lucheInk], startPoint: .top, endPoint: .bottom)
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
                .opacity(isCameraReady ? 1 : 0)
            #endif

            // Frame bar — visible as soon as we have any scored frames.
            VStack {
                Spacer()
                if let frameBuffer, isReady {
                    FrameBarView(frames: frameBuffer.frames)
                }
            }
            .ignoresSafeArea()

            // Top toolbar — zoom badge left, Stop button right (recording only).
            VStack {
                HStack {
                    if isReady {
                        zoomBadge
                            .padding(.leading, 20)
                            .padding(.top, 16)
                    }
                    Spacer()
                    if isRecording {
                        stopButton
                            .padding(.trailing, 20)
                            .padding(.top, 16)
                    }
                }
                Spacer()
            }

            // Center Start button — only in preview mode.
            if isReady && !isRecording {
                centerStartButton
            }

            if !isReady {
                loadingOverlay
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await prepareSession() }
        .onDisappear { stopSession() }
        .preferredOrientation(.landscape)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 18) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.4)
            Text("Preparing camera & model…")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text("This takes a couple of seconds the first time.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(28)
        .background(Color.lucheInk.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Big red circle in the dead-centre of the screen — sized like a typical
    /// camera-app record control.
    private var centerStartButton: some View {
        Button {
            startRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 130, height: 130)
                Text("Start")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .shadow(color: .lucheInk.opacity(0.35), radius: 16, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start recording")
    }

    private var stopButton: some View {
        Button {
            guard !isStopping else { return }
            isStopping = true
            Task { @MainActor in
                await stopAndSave()
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
            .background(Color.lucheInk.opacity(0.55))
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

    // MARK: Session lifecycle

    @MainActor
    private func prepareSession() async {
        sessionID = UUID()
        videoFilename = "\(sessionID.uuidString).mp4"

        // Model load — async, parallel with camera start. The model is
        // selected per-evaluation; each maps to its own .mlpackage in the
        // bundle and has its own I/O contract (per-frame probs for FoG,
        // chunk-level scalar for the regression heads).
        let pickedEvaluation = evaluation
        let inferenceTask = Task.detached { try Inference(for: pickedEvaluation) }

        #if targetEnvironment(simulator)
        videoFilename = nil  // simulator never produces a video file
        isCameraReady = true
        do {
            inference = try await inferenceTask.value
        } catch {
            inference = nil
        }
        let buf = FrameBuffer(inference: inference) { error in
            appState.fail("Inference failed: \(error.localizedDescription)")
        }
        frameBuffer = buf
        isModelLoaded = true
        // Begin preview-mode synthetic stream so the bar runs immediately.
        startSimulatorStream(into: buf)
        #else
        // Construct the FrameBuffer and wire it up before starting the camera
        // so the very first frame goes in.
        do {
            inference = try await inferenceTask.value
            isModelLoaded = true
        } catch {
            appState.fail("Failed to load model: \(error.localizedDescription)")
            return
        }
        let buf = FrameBuffer(inference: inference) { error in
            appState.fail("Inference failed: \(error.localizedDescription)")
        }
        frameBuffer = buf

        // Start the camera in preview-only mode (no mp4 URL yet). Every frame
        // flows into the FrameBuffer so the bar populates immediately; the
        // mp4 writer is attached later on the Start tap.
        await camera.start(videoURL: nil) { buffer in
            Task { @MainActor in
                buf.append(buffer: buffer)
            }
        }
        if case .failed(let msg) = camera.phase {
            appState.fail(msg)
            return
        }
        baseZoom = camera.zoomFactor
        currentZoom = camera.zoomFactor
        isCameraReady = true
        #endif
    }

    @MainActor
    private func startRecording() {
        guard isReady, !isRecording, let buf = frameBuffer else { return }
        // Anchor the save window to the current frame count — everything
        // accumulated during preview is dropped at save time.
        recordingStartFrameIndex = buf.frames.count
        startedAt = Date()
        isRecording = true

        #if !targetEnvironment(simulator)
        if let filename = videoFilename {
            camera.beginRecording(to: VideoStore.fileURL(for: filename))
        }
        #endif
    }

    /// Tap-Stop path: stop capture (await mp4 finalization), then persist and
    /// hand the saved Session to AppState so the Results screen can render.
    @MainActor
    private func stopAndSave() async {
        simTimer?.invalidate()
        simTimer = nil
        #if !targetEnvironment(simulator)
        await camera.stop()
        #endif
        guard let session = saveCurrentSession() else {
            appState.backToMenu()
            return
        }
        appState.finished(session)
    }

    /// onDisappear cleanup: best-effort, don't block.
    private func stopSession() {
        simTimer?.invalidate()
        simTimer = nil
        #if !targetEnvironment(simulator)
        Task { @MainActor in await camera.stop() }
        #endif
    }

    /// Snapshot the per-frame scores from the recording window and persist as
    /// a `Session`. Returns nil if the recording was too short to produce any
    /// scored frames. The required scoreCount differs by evaluation: FoG
    /// expects scoreCount==2 (two overlapping chunks averaged), regression
    /// heads emit one chunk-level scalar so scoreCount==1 is sufficient.
    @discardableResult
    private func saveCurrentSession() -> Session? {
        guard let frameBuffer else {
            cleanupOrphanVideo()
            return nil
        }
        let allFrames = frameBuffer.frames
        let windowStart = min(recordingStartFrameIndex, allFrames.count)
        let window = allFrames[windowStart...]
        let minScoreCount = evaluation.outputIsPerFrame ? 2 : 1
        guard let lastFullyScoredIdx = window.lastIndex(where: { $0.scoreCount >= minScoreCount }) else {
            cleanupOrphanVideo()
            return nil
        }
        let saved = allFrames[windowStart...lastFullyScoredIdx].compactMap { $0.score }
        guard !saved.isEmpty else {
            cleanupOrphanVideo()
            return nil
        }
        let session = Session(
            id: sessionID,
            startedAt: startedAt,
            endedAt: Date(),
            scores: saved,
            device: DeviceInfo.current(),
            videoFilename: videoFilename,
            evaluation: evaluation
        )
        sessions.add(session)
        return session
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
    LiveRecordingScreen(evaluation: .freezingOfGait)
        .environment(AppState())
        .environment(SessionStore())
}
