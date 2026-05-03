import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer. Hands its layer back to
/// `cameraSession` so the rotation coordinator can keep capture and preview
/// horizons aligned.
struct CameraPreviewView: UIViewRepresentable {
    let cameraSession: CameraSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = cameraSession.session
        v.previewLayer.videoGravity = .resizeAspectFill
        cameraSession.attachPreviewLayer(v.previewLayer)
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
