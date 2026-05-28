import SwiftUI
import UIKit

/// Per-screen preferred orientation. iOS 17+ approach: allow all orientations
/// in Info.plist, then ask the window scene to rotate on screen appear.
enum PreferredOrientation {
    case portrait
    case landscape

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait:  return .portrait
        case .landscape: return [.landscapeLeft, .landscapeRight]
        }
    }
}

private struct OrientationLock: ViewModifier {
    let preferred: PreferredOrientation

    func body(content: Content) -> some View {
        content.onAppear {
            request(preferred.mask)
        }
    }

    private func request(_ mask: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene else { return }

        let geo = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scene.requestGeometryUpdate(geo) { _ in }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

extension View {
    func preferredOrientation(_ orientation: PreferredOrientation) -> some View {
        modifier(OrientationLock(preferred: orientation))
    }
}
