import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

/// Destination for live cinematic composite frames.
///
/// Frames arrive as `CMSampleBuffer`s and are enqueued straight into an
/// `AVSampleBufferDisplayLayer`. The first version instead created a `CGImage` per frame and
/// assigned it to `CALayer.contents`: `CIContext.createCGImage` forces a synchronous render plus a
/// fresh allocation for every frame, which is why the cinematic preview ran well under the camera's
/// rate and lagged visibly behind the real preview underneath it. The display layer takes a
/// GPU-resident pixel buffer and shows it — no readback, no per-frame allocation, and SwiftUI is
/// never involved, so nothing in the view tree is invalidated at frame rate.
@MainActor
final class CinematicPreviewSink {
    weak var layer: AVSampleBufferDisplayLayer?

    func submit(_ sampleBuffer: CMSampleBuffer) {
        guard let layer else { return }
        // A display layer that hits an enqueue error stays failed until flushed, and would
        // otherwise show one frozen frame for the rest of the session.
        if layer.status == .failed { layer.flush() }
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            layer.enqueue(sampleBuffer)
        }
    }

    func clear() {
        layer?.flushAndRemoveImage()
    }
}

/// Full-bleed view showing the live cinematic composite (subject sharp, background blurred and
/// graded) over the plain camera preview. Only mounted while Cinematic is on, and never takes
/// touches — tap-to-focus and pinch-to-zoom keep working on the `CameraPreviewView` underneath.
struct CinematicPreviewView: UIViewRepresentable {
    let sink: CinematicPreviewSink

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        view.isUserInteractionEnabled = false
        // Clear, not black: until the first composited frame arrives — and if the pipeline ever
        // fails to produce one — the real camera preview stays visible underneath instead of the
        // screen going black.
        view.backgroundColor = .clear
        // Matches `AVCaptureVideoPreviewLayer`'s `.resizeAspectFill`, so switching Cinematic on
        // and off doesn't visibly re-frame the shot.
        view.displayLayer.videoGravity = .resizeAspectFill
        sink.layer = view.displayLayer
        return view
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {
        sink.layer = uiView.displayLayer
    }

    static func dismantleUIView(_ uiView: DisplayView, coordinator: ()) {
        uiView.displayLayer.flushAndRemoveImage()
    }

    final class DisplayView: UIView {
        override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }
}
