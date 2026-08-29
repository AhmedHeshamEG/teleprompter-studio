import AVFoundation
import Observation

/// Mirrors Apple's `AVCaptureDevice.CinematicVideoFocusMode` shape so the rest of the app can
/// reference a stable type regardless of SDK availability. The raw integers are the platform
/// enum's own values, which is how they reach AVFoundation through `CinematicVideoSupport`.
enum CinematicFocusMode: String, CaseIterable {
    /// Let the system choose and hold focus by itself.
    case none
    /// Hold the tapped subject even when the algorithm would have picked someone else.
    case strong
    /// Prefer the tapped subject, but let the algorithm take focus back when it should.
    case weak

    var platformRawValue: Int {
        switch self {
        case .none: return 0
        case .strong: return 1
        case .weak: return 2
        }
    }
}

/// A detected subject the user can tap to rack focus onto, surfaced from the platform's live
/// cinematic subject-detection metadata.
struct CinematicDetectedSubject: Identifiable, Equatable {
    let id: Int
    /// Normalized 0…1 in AVFoundation's metadata space, origin top-left.
    let boundingBox: CGRect
    /// The focus state the system reports for this subject: 0 none, 1 strong, 2 weak. Non-zero
    /// means Cinematic is currently holding focus on it, which is what the UI draws differently.
    let focusMode: Int

    var isInFocus: Bool { focusMode != 0 }
}

/// Drives Apple's own hardware Cinematic Video capture, where the device supports it.
///
/// Capability detection and the actual switch-on live in `CinematicVideoSupport` +
/// `AVCameraSession`, which reach the API through the Objective-C runtime — the build toolchain's
/// SDK doesn't declare it, but the OS on the device does. This type is the app-facing state:
/// whether it's on, which subjects the system has detected, and which one focus is locked to.
/// `SyntheticCinematicPipeline` remains the fallback whenever the hardware path isn't available or
/// the OS declines it.
@MainActor
@Observable
final class RealCinematicController {
    private(set) var isEnabled = false
    private(set) var detectedSubjects: [CinematicDetectedSubject] = []
    private(set) var lockedSubjectID: Int?

    /// Focus style for taps. Pushed straight down to the session, which is what actually passes it
    /// to `setCinematicVideoTrackingFocus`, so changing it in Settings takes effect on the next tap
    /// rather than at the next session restart.
    var focusMode: CinematicFocusMode = .strong {
        didSet { session?.cinematicFocusModeRawValue = focusMode.platformRawValue }
    }

    /// The session this controller is driving, so `focusMode` changes and taps can reach it.
    private weak var session: AVCameraSession?

    static func isSupported(session: AVCameraSession) -> Bool {
        session.isCinematicSupported
    }

    func enable(on session: AVCameraSession) throws {
        guard CinematicVideoSupport.isAvailableOnThisOS else {
            throw CinematicError.unsupportedOS
        }
        guard session.isCinematicSupported else {
            throw CinematicError.unsupportedDevice
        }
        self.session = session
        session.cinematicFocusModeRawValue = focusMode.platformRawValue
        try session.setCinematicEnabled(true)
        isEnabled = true
    }

    func disable(on session: AVCameraSession) {
        try? session.setCinematicEnabled(false)
        isEnabled = false
        lockedSubjectID = nil
        detectedSubjects = []
    }

    /// Called by the capture pipeline's cinematic metadata delegate as subjects are detected.
    func updateDetectedSubjects(_ subjects: [CinematicDetectedSubject]) {
        detectedSubjects = subjects
        // A subject that has left the frame can't stay "the one in focus".
        if let locked = lockedSubjectID, !subjects.contains(where: { $0.id == locked }) {
            lockedSubjectID = nil
        }
    }

    /// Racks focus for a tap at `normalizedPoint` (AVFoundation device space).
    ///
    /// Prefers focusing by subject ID when the tap lands on (or near) a subject the system has
    /// already detected — that's the precise, tracked rack. Otherwise it hands the raw point to
    /// Cinematic, which searches for a salient object there and starts tracking whatever it finds.
    /// Returns `false` only when the hardware path isn't running, so the caller can fall back to
    /// ordinary autofocus.
    @discardableResult
    func rackFocus(at normalizedPoint: CGPoint, on session: AVCameraSession) -> Bool {
        self.session = session
        session.cinematicFocusModeRawValue = focusMode.platformRawValue

        let candidate = detectedSubjects.min { lhs, rhs in
            distance(from: normalizedPoint, to: lhs.boundingBox) < distance(from: normalizedPoint, to: rhs.boundingBox)
        }
        if let candidate, distance(from: normalizedPoint, to: candidate.boundingBox) < 0.2,
           session.setCinematicFocus(detectedObjectID: candidate.id) {
            lockedSubjectID = candidate.id
            return true
        }

        lockedSubjectID = nil
        return session.setCinematicFocus(at: normalizedPoint)
    }

    private func distance(from point: CGPoint, to box: CGRect) -> CGFloat {
        let center = CGPoint(x: box.midX, y: box.midY)
        return hypot(point.x - center.x, point.y - center.y)
    }
}

enum CinematicError: Error, LocalizedError {
    case unsupportedOS
    case unsupportedDevice

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "Real Cinematic capture requires iOS 26 or later."
        case .unsupportedDevice: return "This device does not support hardware Cinematic capture."
        }
    }
}
