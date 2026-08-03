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
    nonisolated(unsafe) private(set) var blurRadius: Double = 32

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
        guard let writer = assetWriter, let videoInput, let adaptor = pixelBufferAdaptor else { return }

        if sessionStartTime == nil {
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
        }
        guard videoInput.isReadyForMoreMediaData else { return }

        frameCount += 1
        if frameCount % segmentationInterval == 0 || lastMask == nil {
            lastMask = segmenter.segmentationMask(for: pixelBuffer)
        }

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let composited = compositor.composite(source: sourceImage, mask: lastMask, blurRadius: blurRadius)

        guard let pool = adaptor.pixelBufferPool,
              let outputBuffer = compositor.render(composited, into: pool) else { return }
        adaptor.append(outputBuffer, withPresentationTime: presentationTime)
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
