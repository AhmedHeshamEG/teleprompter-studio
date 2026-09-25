import AVFoundation

/// `AVCaptureVideoDataOutput` only supports a single sample buffer delegate. This fans one output
/// out to any number of subscribers (today just `AdaptivePreviewStreamer`, the Companion live
/// monitor), each still responsible for not blocking the shared callback.
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
