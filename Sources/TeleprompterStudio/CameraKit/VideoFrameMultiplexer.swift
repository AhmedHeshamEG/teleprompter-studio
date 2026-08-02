import AVFoundation

/// `AVCaptureVideoDataOutput` only supports a single sample buffer delegate, but Studio needs
/// to feed the same frames to two independent consumers — `AdaptivePreviewStreamer` (Companion
/// live monitor) and `SyntheticCinematicPipeline` (background-blur recording). This fans one
/// output out to many subscribers, each still responsible for not blocking the shared callback.
final class VideoFrameMultiplexer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var subscribers: [AVCaptureVideoDataOutputSampleBufferDelegate] = []

    func add(_ subscriber: AVCaptureVideoDataOutputSampleBufferDelegate) {
        subscribers.append(subscriber)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        for subscriber in subscribers {
            subscriber.captureOutput?(output, didOutput: sampleBuffer, from: connection)
        }
    }
}
