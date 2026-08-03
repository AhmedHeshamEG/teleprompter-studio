import SwiftUI
import UIKit

/// Receives composited cinematic frames and puts them straight on a layer.
///
/// Deliberately *not* `@Observable` state: at 24 fps, publishing each frame into SwiftUI would
/// invalidate the whole Studio view tree 24 times a second, which is precisely the kind of thing
/// that makes an app feel heavy and makes buttons miss taps. Assigning `CALayer.contents` is a
/// direct, allocation-free handoff that SwiftUI never sees.
@MainActor
final class CinematicPreviewSink {
    weak var layer: CALayer?

    func submit(_ image: CGImage) {
        layer?.contents = image
    }

    func clear() {
        layer?.contents = nil
    }
}

/// Full-bleed view showing the live cinematic composite (subject sharp, background blurred and
/// graded) over the plain camera preview. Only mounted while Cinematic is on, and never takes
/// touches — tap-to-focus and pinch-to-zoom keep working on the `CameraPreviewView` underneath.
struct CinematicPreviewView: UIViewRepresentable {
    let sink: CinematicPreviewSink

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        // Matches `AVCaptureVideoPreviewLayer`'s `.resizeAspectFill`, so switching Cinematic on
        // and off doesn't visibly re-frame the shot.
        view.layer.contentsGravity = .resizeAspectFill
        view.layer.masksToBounds = true
        sink.layer = view.layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        sink.layer = uiView.layer
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        uiView.layer.contents = nil
    }
}
