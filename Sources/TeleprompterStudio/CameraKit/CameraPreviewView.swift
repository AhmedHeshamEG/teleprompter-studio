import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let cameraSession: AVCameraSession
    var onTap: ((CGPoint) -> Void)?
    var onPinch: ((CGFloat) -> Void)?
    /// Live Cinematic subject metadata, when the hardware path is running. Drawn here rather than
    /// in SwiftUI because placing a rectangle correctly over a rotated, mirrored,
    /// `resizeAspectFill` preview is exactly what `transformedMetadataObject(for:)` is for — and
    /// because subjects update ~10×/s, which is not a rate to re-render a SwiftUI screen at.
    var subjectRelay: CinematicSubjectRelay?

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
        subjectRelay?.onRawObjects = { [weak view] objects in
            view?.updateSubjects(objects)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onPinch = onPinch
        // Rotation/mirroring are applied directly by `AVCameraSession` (see its `previewLayer`
        // property) the instant they change — nothing to do here.
    }

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: Coordinator) {
        uiView.updateSubjects([])
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

        /// One reusable shape layer per subject, so a moving subject animates its own rectangle
        /// instead of the view rebuilding a layer tree ten times a second.
        private var subjectLayers: [CAShapeLayer] = []

        /// Draws the system's detected Cinematic subjects: a thin rectangle around each, drawn in
        /// the accent colour and thicker for whichever one currently holds focus, so you can see
        /// what a tap would rack focus *to* before you tap it.
        func updateSubjects(_ objects: [AVMetadataObject]) {
            let boxes: [(rect: CGRect, inFocus: Bool)] = objects.compactMap { object in
                guard let transformed = videoPreviewLayer.transformedMetadataObject(for: object) else { return nil }
                guard transformed.bounds.width > 1, transformed.bounds.height > 1 else { return nil }
                return (transformed.bounds, CinematicVideoSupport.focusMode(of: object) != 0)
            }

            while subjectLayers.count < boxes.count {
                let shape = CAShapeLayer()
                shape.fillColor = UIColor.clear.cgColor
                shape.strokeColor = UIColor(Theme.accent).cgColor
                shape.lineWidth = 1.5
                layer.addSublayer(shape)
                subjectLayers.append(shape)
            }
            while subjectLayers.count > boxes.count {
                subjectLayers.removeLast().removeFromSuperlayer()
            }

            // Implicit animations would smear a rectangle across the screen every time a subject
            // is re-reported at a slightly different place.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (shape, box) in zip(subjectLayers, boxes) {
                shape.path = UIBezierPath(roundedRect: box.rect, cornerRadius: 6).cgPath
                shape.lineWidth = box.inFocus ? 2.5 : 1.5
                shape.opacity = box.inFocus ? 1.0 : 0.55
            }
            CATransaction.commit()
        }
    }
}
