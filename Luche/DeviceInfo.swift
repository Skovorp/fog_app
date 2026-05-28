import Foundation
import UIKit

/// Snapshot of the device + app at the moment a session was recorded. Stored
/// per-session inside `Session` so re-exports later — possibly on a different
/// device or after an iOS update — still show the original recording context.
struct DeviceInfo: Codable, Hashable, Sendable {
    let model: String           // "iPhone"
    let name: String            // user-set device name (e.g. "Jacopo's iPhone")
    let systemName: String      // "iOS"
    let systemVersion: String   // "17.4"
    let identifier: String      // "iPhone15,3" (from utsname.machine)
    let appVersion: String      // CFBundleShortVersionString
    let appBuild: String        // CFBundleVersion

    @MainActor
    static func current() -> DeviceInfo {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(String(UnicodeScalar(UInt8(value))))
        }
        let info = Bundle.main.infoDictionary ?? [:]
        return DeviceInfo(
            model: UIDevice.current.model,
            name: UIDevice.current.name,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            identifier: identifier,
            appVersion: (info["CFBundleShortVersionString"] as? String) ?? "?",
            appBuild: (info["CFBundleVersion"] as? String) ?? "?"
        )
    }

    /// Plain dictionary form used by `SessionExport.generateAllJSON`.
    var jsonDict: [String: String] {
        [
            "model": model,
            "name": name,
            "system_name": systemName,
            "system_version": systemVersion,
            "identifier": identifier,
            "app_version": appVersion,
            "app_build": appBuild,
        ]
    }
}
