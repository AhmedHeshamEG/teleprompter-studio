import Observation
import UIKit

/// User-selectable rotation behavior for the whole app, cycled from the button in Studio's top bar
/// (and still settable from Studio Settings).
///
/// `.auto` follows the physical device; `.portrait`/`.landscape` pin the app so it stops following
/// the accelerometer, for people who deliberately mount the phone one way and don't want an
/// accidental tilt to flip the layout mid-take.
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

    /// Next state in the on-screen button's cycle.
    var next: OrientationLock {
        switch self {
        case .auto: return .portrait
        case .portrait: return .landscape
        case .landscape: return .auto
        }
    }

    var systemImage: String {
        switch self {
        case .auto: return "arrow.clockwise"
        case .portrait: return "rectangle.portrait"
        case .landscape: return "rectangle"
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

    private init() {
        // `UIDevice.orientation` is only populated while the device is generating orientation
        // notifications. Without this it reads `.unknown` forever — which is why switching back to
        // Auto did nothing until the phone was physically turned: there was no current orientation
        // to adopt.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    private func applyChange() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

        // Asking for a *set* of orientations doesn't move the window: iOS keeps whatever it is
        // currently showing as long as it's still in the set. Coming back from a lock, that meant
        // the app stayed pinned in the orientation the lock had forced and only corrected on the
        // next physical rotation — the "Auto doesn't pick up how I'm holding the phone" bug. So
        // request the single orientation the device is actually in first, then hand control back
        // by widening to the full mask on the next runloop turn.
        let target = resolvedOrientation(for: lock)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        guard target != lock.mask else { return }
        DispatchQueue.main.async { [lock] in
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: lock.mask)) { _ in }
        }
    }

    /// The single orientation to snap to, chosen from how the phone is physically held: the exact
    /// one for `.auto`, and the matching *side* for `.landscape` so a phone already on its left
    /// side doesn't flip to the right one on the way into the lock.
    private func resolvedOrientation(for lock: OrientationLock) -> UIInterfaceOrientationMask {
        let device = UIDevice.current.orientation
        switch lock {
        case .portrait:
            return .portrait
        case .landscape:
            // `.landscapeLeft` on the device is `.landscapeRight` on the interface: the device
            // reports which way its *home edge* points, the interface which way its *content* is
            // rotated. Getting this backwards is a 180° flip, not a no-op.
            return device == .landscapeRight ? .landscapeLeft : .landscapeRight
        case .auto:
            switch device {
            case .portrait: return .portrait
            case .landscapeLeft: return .landscapeRight
            case .landscapeRight: return .landscapeLeft
            // Face up/down/unknown carry no usable rotation — leave the app where it is and just
            // re-open the full mask.
            default: return lock.mask
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.shared.lock.mask
    }
}
