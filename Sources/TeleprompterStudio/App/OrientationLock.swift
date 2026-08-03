import Observation
import UIKit

/// User-selectable rotation behavior for the whole app, set from `StudioSettingsSheet`.
/// `.auto` is the default and just tracks the device's physical orientation (this is already
/// what happens once `Info.plist` allows more than portrait); `.portrait`/`.landscape` pin the
/// app so it stops following the accelerometer, for people who deliberately mount the phone one
/// way and don't want an accidental tilt to flip the layout mid-take.
enum OrientationLock: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case portrait = "Portrait"
    case landscape = "Landscape"

    var id: String { rawValue }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .auto: return [.portrait, .landscapeLeft, .landscapeRight]
        case .portrait: return .portrait
        case .landscape: return [.landscapeLeft, .landscapeRight]
        }
    }
}

/// Bridges the SwiftUI-selectable `OrientationLock` to UIKit, which is where orientation is
/// actually enforced (`application(_:supportedInterfaceOrientationsFor:)`). A plain singleton
/// rather than something threaded through the view hierarchy because `AppDelegate` needs to
/// reach it without any SwiftUI environment available.
@MainActor
@Observable
final class OrientationController {
    static let shared = OrientationController()

    var lock: OrientationLock = .auto {
        didSet { applyChange() }
    }

    private init() {}

    private func applyChange() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: lock.mask)) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.shared.lock.mask
    }
}
