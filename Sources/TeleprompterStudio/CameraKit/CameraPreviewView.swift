import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let cameraSession: AVCameraSession
    var onTap: ((CGPoint) -> Void)?
    var onPinch: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = cameraSession.captureSession
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        // `AVCameraSession` applies rotation/mirroring to this layer's connection directly and
        // immediately whenever they change (see its `previewLayer` doc comment) — this is the
        // single source of truth, not `updateUIView` below, which SwiftUI does not reliably
        // re-invoke on every rotation/facing change.
        cameraSession.previewLayer = view.videoPreviewLayer

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinchGesture)

        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onPinch = onPinch
        // Rotation/mirroring are applied directly by `AVCameraSession` (see its `previewLayer`
        // property) the instant they change — nothing to do here.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var view: PreviewUIView?
        var onTap: ((CGPoint) -> Void)?
        var onPinch: ((CGFloat) -> Void)?
        var pinchStartZoom: CGFloat = 1.0

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            onTap?(devicePoint)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            onPinch?(gesture.scale)
        }
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
