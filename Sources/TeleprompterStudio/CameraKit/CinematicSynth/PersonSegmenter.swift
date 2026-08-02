import CoreImage
import Vision

/// Runs Vision's person-segmentation request on each frame to produce an alpha mask used to
/// keep the subject sharp while blurring the background (the synthetic "cinematic" fallback for
/// devices/OS versions without hardware Cinematic capture).
final class PersonSegmenter {
    private let requestHandler = VNSequenceRequestHandler()

    /// Returns a grayscale mask (`CIImage`, subject = white / 1.0, background = black / 0.0)
    /// sized to match `pixelBuffer`, or `nil` if segmentation failed for this frame (compositor
    /// should fall back to the previous mask or an all-sharp frame rather than stall capture).
    func segmentationMask(for pixelBuffer: CVPixelBuffer) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        do {
            try requestHandler.perform([request], on: pixelBuffer)
        } catch {
            return nil
        }

        guard let result = request.results?.first else { return nil }
        return CIImage(cvPixelBuffer: result.pixelBuffer)
    }
}
