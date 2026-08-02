import AVFoundation
import CoreImage
import Observation
import UIKit

/// Downscales + JPEG-compresses camera frames and hands them to `SyncCoordinator` for the
/// Companion's live monitor view (~540p @ 15-20fps target, per spec). This is the single
/// heaviest piece of the sync feature, so it actively degrades itself under pressure instead of
/// ever blocking capture: if encoding+sending falls behind, it drops frames first, then lowers
/// resolution/fps, and if that's still not enough, disables video entirely and tells the
/// Companion to fall back to prompter-mirror-only — never queues up stale frames.
final class AdaptivePreviewStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let processingQueue = DispatchQueue(label: "studio.sync.previewEncode", qos: .utility)

    private nonisolated(unsafe) var targetHeight: CGFloat = 540
    private nonisolated(unsafe) var targetFPS: Double = 18
    private nonisolated(unsafe) var jpegQuality: CGFloat = 0.5
    private nonisolated(unsafe) var isEnabled = true
    private nonisolated(unsafe) var lastEmitTime: CFAbsoluteTime = 0
    private nonisolated(unsafe) var isBusy = false
    private nonisolated(unsafe) var consecutiveSlowFrames = 0
    private nonisolated(unsafe) var consecutiveFastFrames = 0

    /// Set by the owning view model; called on `processingQueue` with the finished JPEG.
    var onFrameEncoded: ((Data) -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isEnabled, !isBusy else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmitTime >= 1.0 / targetFPS else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isBusy = true
        lastEmitTime = now

        processingQueue.async { [weak self] in
            guard let self else { return }
            let start = CFAbsoluteTimeGetCurrent()
            defer { self.isBusy = false }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let scale = self.targetHeight / ciImage.extent.height
            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            guard let cgImage = self.context.createCGImage(scaled, from: scaled.extent) else { return }
            let uiImage = UIImage(cgImage: cgImage)
            guard let jpeg = uiImage.jpegData(compressionQuality: self.jpegQuality) else { return }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            self.adapt(encodeDuration: elapsed)

            self.onFrameEncoded?(jpeg)
        }
    }

    /// Simple hysteresis-based quality ladder: consistently slow encodes step resolution/fps/
    /// quality down; consistently fast encodes step back up, capped at the spec's target.
    private func adapt(encodeDuration: TimeInterval) {
        let budget = 1.0 / targetFPS
        if encodeDuration > budget * 0.8 {
            consecutiveSlowFrames += 1
            consecutiveFastFrames = 0
        } else {
            consecutiveFastFrames += 1
            consecutiveSlowFrames = 0
        }

        if consecutiveSlowFrames > 8 {
            consecutiveSlowFrames = 0
            stepDown()
        } else if consecutiveFastFrames > 30 {
            consecutiveFastFrames = 0
            stepUp()
        }
    }

    private func stepDown() {
        if jpegQuality > 0.3 {
            jpegQuality -= 0.1
        } else if targetFPS > 8 {
            targetFPS -= 4
        } else if targetHeight > 240 {
            targetHeight -= 90
        } else {
            // Already at the floor and still can't keep up: disable video, keep prompter-mirror alive.
            if isEnabled {
                isEnabled = false
                DispatchQueue.main.async { [weak self] in self?.onAvailabilityChanged?(false) }
            }
        }
    }

    private func stepUp() {
        guard isEnabled else { return }
        if targetHeight < 540 {
            targetHeight += 90
        } else if targetFPS < 18 {
            targetFPS += 4
        } else if jpegQuality < 0.5 {
            jpegQuality += 0.1
        }
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        isEnabled = enabled
        if enabled, !wasEnabled {
            targetHeight = 270
            targetFPS = 10
            jpegQuality = 0.35
            DispatchQueue.main.async { [weak self] in self?.onAvailabilityChanged?(true) }
        } else if !enabled {
            DispatchQueue.main.async { [weak self] in self?.onAvailabilityChanged?(false) }
        }
    }
}
