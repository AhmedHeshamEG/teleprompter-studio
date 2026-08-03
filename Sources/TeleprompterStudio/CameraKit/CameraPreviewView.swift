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

        // Keeps the preview upright as the device rotates; `previewRotationAngle` is driven
        // live by `AVCameraSession`'s `AVCaptureDevice.RotationCoordinator` observers.
        let angle = cameraSession.previewRotationAngle
        if let connection = uiView.videoPreviewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        // Mirror the preview layer to match `videoDataOutput`/`movieFileOutput` exactly —
        // relying on the preview layer's own automatic mirroring let it disagree with the
        // capture connections, which is what produced the inconsistent/inverted preview.
        if let connection = uiView.videoPreviewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraSession.isMirrored
        }
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
