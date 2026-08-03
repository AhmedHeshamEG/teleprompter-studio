import AVFoundation
import CoreImage
import Observation

/// Live segmentation + Core Image background blur, recorded via `AVAssetWriter`. This is the
/// fallback "cinematic" path for devices/OS versions without hardware Cinematic capture
/// (`RealCinematicController`). Runs entirely on `processingQueue`; never blocks the capture
/// session's own delegate callback longer than one frame — if segmentation falls behind, frames
/// are composited with the last-known mask rather than dropped, so recording never stalls.
final class SyntheticCinematicPipeline: NSObject {
    /// Not `@MainActor` itself (its owner, `SyntheticCinematicPipeline`, isn't actor-isolated
    /// either — see the class doc comment) — every write is already routed through
    /// `Task { @MainActor in ... }` at the call site, so SwiftUI only ever observes main-thread
    /// changes without needing the type itself to be actor-isolated.
    @Observable final class State {
        var isRunning = false
        var isSimulatedLabelVisible = true
    }

    let state = State()

    /// Adjustable "aperture" blur amount. Written from the main-actor UI slider, read from
    /// `processingQueue` on every frame; plain `Double` writes/reads are word-atomic on all
    /// Apple platforms and the value only ever needs to be "recent", not perfectly synchronized.
    nonisolated(unsafe) private(set) var blurRadius: Double = 46

    func setBlurRadius(_ value: Double) {
        blurRadius = value
    }

    private let segmenter = PersonSegmenter()
    private let compositor = BokehCompositor()
    private let processingQueue = DispatchQueue(label: "studio.cinematic.synth", qos: .userInitiated)

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStartTime: CMTime?
    private var lastMask: CIImage?
    private var outputURL: URL?

    /// Live WYSIWYG preview. Turning Cinematic on used to change nothing you could see — the
    /// blur only existed inside the recorded file, so the toggle read as broken and there was no
    /// way to judge the effect before shooting. With this on, the same composite that gets written
    /// to disk is also rendered to screen. Off by default and only turned on with the Cinematic
    /// toggle, so a normal session pays nothing for it.
    nonisolated(unsafe) private var isPreviewEnabled = false
    /// Called on the main thread with a display-ready composited frame.
    var onPreviewFrame: ((CMSampleBuffer) -> Void)?
    private var lastPreviewEmit: CFAbsoluteTime = 0
    /// Preview composites at screen resolution rather than capture resolution — the effect only
    /// has to fill a phone screen — but at the full capture rate. Running it at 24fps under a 30fps
    /// camera produced a visible judder against the real preview, which is a large part of why the
    /// effect looked cheap.
    private let previewTargetFPS: Double = 30
    /// Sized by the frame's **short** side. Sizing by height (as this did) meant an upright
    /// portrait frame — 1080×1920 — got scaled down to 405×720 and then blown back up across a
    /// full-height phone screen: a soft, obviously-lower-resolution image sitting on top of a
    /// razor-sharp camera preview. Capping the short side instead keeps the composite at roughly
    /// screen resolution in either orientation.
    private let previewTargetShortSide: CGFloat = 720

    /// Degrees of rotation between how frames arrive on this output (rotated for *capture*, so the
    /// recorded file is upright) and how the camera preview is rotated on screen (rotated for the
    /// current interface orientation). Normally zero: both track the device. They diverge when the
    /// interface is orientation-locked and the phone is physically turned — at which point the
    /// composite would be drawn 90° out of step with the preview it's covering.
    nonisolated(unsafe) private var previewRotationDelta: Double = 0

    private var previewPool: CVPixelBufferPool?
    private var previewPoolSize: CGSize = .zero
    private var previewFormatDescription: CMFormatDescription?

    func setPreviewEnabled(_ enabled: Bool) {
        processingQueue.async { [weak self] in
            self?.isPreviewEnabled = enabled
            self?.lastPreviewEmit = 0
            if !enabled {
                self?.previewPool = nil
                self?.previewFormatDescription = nil
                self?.previewPoolSize = .zero
            }
        }
    }

    func setPreviewRotation(delta degrees: Double) {
        previewRotationDelta = degrees
    }

    private var frameCount = 0
    /// Run segmentation on every Nth frame and reuse the mask in between — full per-frame
    /// segmentation is unnecessary for a blur effect and would compete with encoding for GPU time.
    private let segmentationInterval = 2

    func start(dimensions: (width: Int, height: Int), audioEnabled: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
            ]
        )
        guard writer.canAdd(vInput) else { throw RecorderError.saveFailed("Cannot add video input") }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        if audioEnabled {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 64000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                aInput = input
            }
        }

        writer.startWriting()

        assetWriter = writer
        videoInput = vInput
        audioInput = aInput
        pixelBufferAdaptor = adaptor
        outputURL = url
        sessionStartTime = nil
        frameCount = 0
        lastMask = nil

        Task { @MainActor in state.isRunning = true }
        return url
    }

    func stop() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self, let writer = self.assetWriter else {
                    continuation.resume(throwing: RecorderError.notRecording)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    Task { @MainActor in self.state.isRunning = false }
                    if writer.status == .completed, let url = self.outputURL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: writer.error ?? RecorderError.saveFailed("Unknown asset writer error"))
                    }
                }
            }
        }
    }
}

// `AVCaptureVideoDataOutputSampleBufferDelegate` and `AVCaptureAudioDataOutputSampleBufferDelegate`
// both declare the identical `captureOutput(_:didOutput:from:)` requirement; one implementation
// satisfies both conformances, distinguishing frames by which `AVCaptureOutput` called in.
extension SyntheticCinematicPipeline: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            handleAudioSampleBuffer(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        processingQueue.async { [weak self] in
            self?.processVideoFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        }
    }

    private func processVideoFrame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let isRecording = assetWriter != nil && videoInput != nil && pixelBufferAdaptor != nil
        guard isRecording || isPreviewEnabled else { return }

        frameCount += 1
        if frameCount % segmentationInterval == 0 || lastMask == nil {
            lastMask = segmenter.segmentationMask(for: pixelBuffer)
        }
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)

        if isRecording {
            appendRecordingFrame(sourceImage, pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        }
        if isPreviewEnabled {
            emitPreviewFrame(from: sourceImage, presentationTime: presentationTime)
        }
    }

    private func appendRecordingFrame(_ sourceImage: CIImage, pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let writer = assetWriter, let videoInput, let adaptor = pixelBufferAdaptor else { return }

        if sessionStartTime == nil {
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
        }
        guard videoInput.isReadyForMoreMediaData else { return }

        let composited = compositor.composite(source: sourceImage, mask: lastMask, blurRadius: blurRadius)
        guard let pool = adaptor.pixelBufferPool,
              let outputBuffer = compositor.render(composited, into: pool) else { return }
        adaptor.append(outputBuffer, withPresentationTime: presentationTime)
    }

    /// Composites a downscaled copy for the on-screen preview. Downscaling first is what keeps
    /// this affordable: the expensive filters (blur, mask feather, grade) all cost in proportion to
    /// pixel count, and the result only ever has to fill a phone screen. The blur radius is scaled
    /// to match so the preview shows the same *look*, not a different one.
    private func emitPreviewFrame(from sourceImage: CIImage, presentationTime: CMTime) {
        let now = CFAbsoluteTimeGetCurrent()
        // Small tolerance, or a camera running at exactly the preview rate loses every other frame
        // to a fractional-millisecond overshoot.
        guard now - lastPreviewEmit >= (1.0 / previewTargetFPS) - 0.002 else { return }
        lastPreviewEmit = now

        let extent = sourceImage.extent
        let shortSide = min(extent.width, extent.height)
        guard shortSide > 1 else { return }
        let scale = min(1, previewTargetShortSide / shortSide)
        let scaled = scale < 1
            ? sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : sourceImage

        let composited = compositor.composite(source: scaled, mask: lastMask, blurRadius: blurRadius * Double(scale))
        let oriented = orientedForDisplay(composited)
        guard let sampleBuffer = previewSampleBuffer(from: oriented, presentationTime: presentationTime) else { return }
        let callback = onPreviewFrame
        DispatchQueue.main.async { callback?(sampleBuffer) }
    }

    /// Applies `previewRotationDelta` and normalises the result back to a zero origin.
    ///
    /// `CIImage` transforms work in a y-up space, so a clockwise on-screen rotation of N degrees is
    /// a rotation of −N here.
    private func orientedForDisplay(_ image: CIImage) -> CIImage {
        let degrees = previewRotationDelta
        guard abs(degrees) > 0.5 else { return image }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: -degrees * .pi / 180))
        return rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.origin.x,
            y: -rotated.extent.origin.y
        ))
    }

    /// Renders the composite into a pooled pixel buffer and wraps it as a `CMSampleBuffer` marked
    /// for immediate display, which is what `AVSampleBufferDisplayLayer` wants for a live feed
    /// (no timebase, no scheduling — show this now).
    private func previewSampleBuffer(from image: CIImage, presentationTime: CMTime) -> CMSampleBuffer? {
        let size = CGSize(width: image.extent.width.rounded(), height: image.extent.height.rounded())
        guard size.width >= 1, size.height >= 1 else { return nil }

        if previewPool == nil || previewPoolSize != size {
            previewPool = Self.makePixelBufferPool(width: Int(size.width), height: Int(size.height))
            previewPoolSize = size
            previewFormatDescription = nil
        }
        guard let pool = previewPool,
              let pixelBuffer = compositor.render(image, into: pool) else { return nil }

        if previewFormatDescription == nil {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            previewFormatDescription = description
        }
        guard let formatDescription = previewFormatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private static func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // IOSurface-backed, so the display layer can show the buffer without a CPU copy.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        return pool
    }
}

private extension SyntheticCinematicPipeline {
    func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self] in
            guard let self, let audioInput = self.audioInput, self.sessionStartTime != nil else { return }
            guard audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }
}
