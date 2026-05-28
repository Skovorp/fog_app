import AVFoundation
import Foundation
import Observation

/// Continuously captures video at 24 fps from the back camera and forwards each
/// frame (deep-copied CVPixelBuffer) to `onFrame`. Unlike v1, there is no auto-stop:
/// recording runs until `stop()` is called.
///
/// Camera doesn't work in the iOS Simulator — `LiveRecordingScreen` falls back to
/// a synthetic timer in that case.
@MainActor
@Observable
final class CameraSession: NSObject {
    enum Phase: Equatable {
        case idle
        case configuring
        case capturing
        case stopped
        case failed(String)
    }

    var phase: Phase = .idle
    var frameCount: Int = 0

    let targetFPS: Int = 24

    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "luche.camera.video", qos: .userInitiated)
    private var output: AVCaptureVideoDataOutput?
    private var device: AVCaptureDevice?
    private var onFrame: ((CVPixelBuffer) -> Void)?

    /// Writer is non-isolated and only ever touched from `videoQueue`.
    private nonisolated let videoWriter = VideoWriter()

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservers: [NSKeyValueObservation] = []

    /// Called by CameraPreviewView once its layer is hosted in the view hierarchy.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if device != nil {
            setupRotationCoordinator()
        }
    }

    /// `videoURL` (when non-nil) is the file the AVAssetWriter will write to.
    /// Pass nil to skip recording (e.g. simulator or low-storage scenarios).
    func start(videoURL: URL?, onFrame: @escaping (CVPixelBuffer) -> Void) async {
        self.onFrame = onFrame

        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            phase = .failed("Camera permission denied")
            return
        }

        phase = .configuring
        do {
            try configureSession()
        } catch {
            phase = .failed("Camera setup failed: \(error.localizedDescription)")
            return
        }

        if previewLayer != nil {
            setupRotationCoordinator()
        }

        frameCount = 0
        phase = .capturing

        // Hand the URL to the writer on `videoQueue` *before* startRunning so
        // it sees the URL by the time the first sample buffer arrives.
        videoQueue.async { [videoWriter, session] in
            videoWriter.reset(url: videoURL)
            session.startRunning()
        }
    }

    /// Switch from preview-only to recording. Must be called after `start(...)`
    /// returned and the session is `.capturing`. The next sample buffer that
    /// arrives on `videoQueue` will lazily configure the AVAssetWriter — there
    /// is no separate "start writing" handshake.
    func beginRecording(to url: URL) {
        videoQueue.async { [videoWriter] in
            videoWriter.reset(url: url)
        }
    }

    /// Stop capture and finalize the video file (if recording). Returns when
    /// the .mp4 is fully flushed to disk and safe to read.
    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            videoQueue.async { [videoWriter, session] in
                if session.isRunning { session.stopRunning() }
                videoWriter.finish {
                    cont.resume()
                }
            }
        }
        rotationObservers.removeAll()
        rotationCoordinator = nil
        phase = .stopped
        onFrame = nil
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // Prefer multi-lens virtual devices so pinch can drop into the ultrawide
        // (= 0.5× in Camera-app terms) on phones that have one. Falls back to
        // the plain wide lens on older iPhones with a single back camera.
        let candidates: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        guard let device = candidates.lazy
            .compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) })
            .first else {
            throw NSError(domain: "Luche.CameraSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "No back camera"])
        }
        self.device = device

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "Luche.CameraSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        try device.lockForConfiguration()
        let frameDuration = CMTime(value: 1, timescale: Int32(targetFPS))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        // Default to the widest available FOV (the ultrawide on multi-cam
        // virtual devices). User can pinch in from there.
        device.videoZoomFactor = device.minAvailableVideoZoomFactor
        device.unlockForConfiguration()

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "Luche.CameraSession", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)

        self.output = output
    }

    /// Apple's recommended way to compute the correct rotation for capture and
    /// preview connections (iOS 17+). The coordinator updates as the device
    /// physically rotates; we KVO it and push the new angles to both the data
    /// output connection (so frames hit the model upright) and the preview
    /// layer connection (so what the user sees matches).
    private func setupRotationCoordinator() {
        guard let device else { return }
        rotationObservers.removeAll()

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        applyCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)

        rotationObservers.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, change in
                guard let new = change.newValue else { return }
                Task { @MainActor in self?.applyCaptureAngle(new) }
            }
        )
        rotationObservers.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let new = change.newValue else { return }
                Task { @MainActor in self?.applyPreviewAngle(new) }
            }
        )
    }

    private func applyCaptureAngle(_ angle: CGFloat) {
        guard let conn = output?.connection(with: .video) else { return }
        if conn.isVideoRotationAngleSupported(angle) {
            conn.videoRotationAngle = angle
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        guard let conn = previewLayer?.connection else { return }
        if conn.isVideoRotationAngleSupported(angle) {
            conn.videoRotationAngle = angle
        }
    }

    // MARK: Zoom (pinch-to-zoom on the live preview)

    var minZoomFactor: CGFloat { device?.minAvailableVideoZoomFactor ?? 1 }

    /// Capped at 20× *display* zoom on every device. Raw `videoZoomFactor` is
    /// offset by `zoomDivisor` (e.g. 2.0 on a triple camera, where raw=2.0
    /// shows as 1.0×), so the raw cap is `20 * zoomDivisor`. Some Pro phones
    /// report `maxAvailableVideoZoomFactor` ≥ 100 raw — past 20× display the
    /// digital crop is unusably soft for inference.
    var maxZoomFactor: CGFloat {
        guard let device else { return 1 }
        return min(device.maxAvailableVideoZoomFactor, 20 * zoomDivisor)
    }

    var zoomFactor: CGFloat { device?.videoZoomFactor ?? 1 }

    /// Divisor that converts AVFoundation's raw `videoZoomFactor` into the
    /// Camera-app-style display number (where the wide lens is "1.0×" and the
    /// ultrawide is "0.5×"). For a multi-cam virtual device this is the first
    /// switch-over factor (UW → Wide); for a single-lens device it's 1.
    var zoomDivisor: CGFloat {
        guard let device else { return 1 }
        if let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(truncating: first)
        }
        return 1
    }

    func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        let clamped = min(max(factor, minZoomFactor), maxZoomFactor)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            // Couldn't acquire the device lock — silently ignore; the next
            // pinch update will retry.
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 1. Append to the video file (no-op when no URL was set).
        videoWriter.handle(sampleBuffer)

        // 2. Forward a deep copy to the inference path on main.
        let copied = Self.copyPixelBuffer(pixelBuffer)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.phase == .capturing else { return }
            self.frameCount &+= 1
            self.onFrame?(copied)
        }
    }

    nonisolated private static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)

        var copy: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &copy)
        guard let dst = copy else { return source }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        if let s = CVPixelBufferGetBaseAddress(source),
           let d = CVPixelBufferGetBaseAddress(dst) {
            let rowBytes = CVPixelBufferGetBytesPerRow(source)
            memcpy(d, s, rowBytes * height)
        }
        return dst
    }
}

// MARK: - Video file recording

/// Owns the AVAssetWriter for one capture session. All methods are intended
/// to be called from a single serial queue (the camera's `videoQueue`).
/// Marked `@unchecked Sendable` so it can be referenced from an actor-isolated
/// CameraSession; the queue contract guarantees thread safety.
final class VideoWriter: @unchecked Sendable {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var pendingURL: URL?
    private var started = false

    /// Set the destination for the next capture. Pass nil to disable recording.
    /// Must be called before the first sample buffer arrives.
    func reset(url: URL?) {
        pendingURL = url
        started = false
        writer = nil
        input = nil
    }

    /// Append a sample buffer if recording is active. Lazily configures the
    /// writer using the first buffer's dimensions so the file resolution
    /// matches whatever the connection actually produces (post-rotation).
    func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let url = pendingURL else { return }
        if !started {
            setup(url: url, sampleBuffer: sampleBuffer)
            started = true
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Finalize the file. Calls completion when the .mp4 is fully on disk.
    func finish(completion: @escaping () -> Void) {
        guard started, let writer, let input else {
            reset(url: nil)
            completion()
            return
        }
        input.markAsFinished()
        writer.finishWriting {
            completion()
        }
        self.writer = nil
        self.input = nil
        self.started = false
        self.pendingURL = nil
    }

    private func setup(url: URL, sampleBuffer: CMSampleBuffer) {
        try? FileManager.default.removeItem(at: url)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height),
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            guard writer.startWriting() else {
                print("[VideoWriter] startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            self.writer = writer
            self.input = input
        } catch {
            print("[VideoWriter] setup failed: \(error.localizedDescription)")
        }
    }
}
