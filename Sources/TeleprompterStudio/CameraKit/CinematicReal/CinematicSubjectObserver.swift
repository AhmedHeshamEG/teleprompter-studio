import AVFoundation
import Foundation
import QuartzCore

/// Hand-off point for live Cinematic subject metadata.
///
/// Two consumers want the same stream for different reasons, and neither should pull the other's
/// cost along: `RealCinematicController` wants lightweight value types so a tap can be matched to a
/// subject ID, while the camera preview wants the *original* `AVMetadataObject`s so it can convert
/// their bounds through `AVCaptureVideoPreviewLayer.transformedMetadataObject(for:)` — the only
/// correct way to place a rectangle over a `resizeAspectFill` preview that is also rotated and
/// possibly mirrored.
///
/// Deliberately not `@Observable`: subjects update many times a second, and publishing them as
/// observed state read from a SwiftUI body would invalidate the whole Studio screen at that rate —
/// the exact mistake the rest of this screen was rebuilt to avoid.
final class CinematicSubjectRelay {
    /// Called on the main thread with the raw metadata objects, for the preview overlay.
    var onRawObjects: (([AVMetadataObject]) -> Void)?
    /// Called on the main thread with app-level subjects, for focus targeting.
    var onSubjects: (([CinematicDetectedSubject]) -> Void)?
}

/// `AVCaptureMetadataOutput` delegate for Cinematic subject detection.
///
/// An `NSObject` of its own rather than a conformance on `CameraStudioViewModel`, because the
/// delegate is called on a background capture queue and the view model is `@MainActor` — this is
/// where the thread hop belongs.
final class CinematicSubjectObserver: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private let relay: CinematicSubjectRelay
    /// Subject detection reports at the capture frame rate. Ten updates a second is well past what
    /// the eye reads as "the box follows me", and it keeps the main thread out of it the rest of
    /// the time.
    private var lastDelivery: CFTimeInterval = 0
    private let minimumInterval: CFTimeInterval = 0.1

    init(relay: CinematicSubjectRelay) {
        self.relay = relay
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        // An empty report always goes through: "everyone left the frame" is exactly the update
        // that must not be throttled away, or stale rectangles hang on screen.
        guard metadataObjects.isEmpty || now - lastDelivery >= minimumInterval else { return }
        lastDelivery = now

        let subjects: [CinematicDetectedSubject] = metadataObjects.compactMap { object in
            guard let id = CinematicVideoSupport.detectedObjectID(of: object) else { return nil }
            return CinematicDetectedSubject(
                id: id,
                boundingBox: object.bounds,
                focusMode: CinematicVideoSupport.focusMode(of: object)
            )
        }

        DispatchQueue.main.async { [relay] in
            relay.onRawObjects?(metadataObjects)
            relay.onSubjects?(subjects)
        }
    }
}
