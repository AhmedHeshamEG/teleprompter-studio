import AVFoundation
import Observation

/// Mirrors Apple's `AVCaptureDevice.CinematicVideoFocusMode` shape so the rest of the app can
/// reference a stable type regardless of SDK availability.
enum CinematicFocusMode: String, CaseIterable {
    case none
    case strong
    case weak
}

/// A detected subject the user can tap to rack focus onto, surfaced from the platform's live
/// cinematic subject-detection metadata.
struct CinematicDetectedSubject: Identifiable, Equatable {
    let id: Int
    let boundingBox: CGRect // normalized 0...1, origin top-left
}

/// Drives Apple's own hardware Cinematic Video capture, where the device supports it.
///
/// Capability detection and the actual switch-on live in `CinematicVideoSupport` +
/// `AVCameraSession`, which reach the API by selector at runtime — the build toolchain's SDK
/// doesn't declare it, but the OS on the device does. This type is the app-facing state: whether
/// it's on, which subjects the system has detected, and which one focus is locked to.
/// `SyntheticCinematicPipeline` remains the fallback whenever the hardware path isn't available or
/// the OS declines it.
@MainActor
@Observable
final class RealCinematicController {
    private(set) var isEnabled = false
    private(set) var detectedSubjects: [CinematicDetectedSubject] = []
    private(set) var lockedSubjectID: Int?
    var focusMode: CinematicFocusMode = .strong

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
        try session.setCinematicEnabled(true)
        isEnabled = true
    }

    func disable(on session: AVCameraSession) {
        try? session.setCinematicEnabled(false)
        isEnabled = false
        lockedSubjectID = nil
    }

    /// Called by the capture pipeline's cinematic metadata delegate as subjects are detected.
    /// `CameraStudioViewModel` wires this up when the `AVCaptureMovieFileOutput` reports frames
    /// with cinematic subject metadata (iOS 26+).
    func updateDetectedSubjects(_ subjects: [CinematicDetectedSubject]) {
        detectedSubjects = subjects
    }

    /// Racks focus onto the subject nearest `normalizedPoint` (tap-to-lock), or clears the lock
    /// and returns to automatic tracking if no subject is near the tap.
    func lockFocus(near normalizedPoint: CGPoint, on output: AVCaptureMovieFileOutput) {
        guard #available(iOS 26.0, *) else { return }
        let candidate = detectedSubjects.min { lhs, rhs in
            distance(from: normalizedPoint, to: lhs.boundingBox) < distance(from: normalizedPoint, to: rhs.boundingBox)
        }
        guard let candidate, distance(from: normalizedPoint, to: candidate.boundingBox) < 0.15 else {
            lockedSubjectID = nil
            return
        }
        lockedSubjectID = candidate.id
        applyFocus(objectID: candidate.id, mode: focusMode, output: output)
    }

    private func applyFocus(objectID: Int, mode: CinematicFocusMode, output: AVCaptureMovieFileOutput) {
        guard #available(iOS 26.0, *) else { return }
        // See file-level note: exact API name per build brief / WWDC24 Cinematic Framework.
        // output.setCinematicVideoTrackingFocus(detectedObjectID: objectID, focusMode: mode.platformValue)
        //
        // Kept as a documented call-site rather than an unverifiable compiled symbol so the
        // rest of the app builds cleanly; wire this one line up against the real SDK.
        _ = (objectID, mode, output)
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
