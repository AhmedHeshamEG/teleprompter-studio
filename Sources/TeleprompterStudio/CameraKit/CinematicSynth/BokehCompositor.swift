import CoreImage
import CoreImage.CIFilterBuiltins

/// Composites a sharp foreground (masked by the segmentation result) over a Gaussian-blurred
/// background, i.e. a synthetic depth-of-field / "bokeh" effect. Runs entirely on the GPU via a
/// Metal-backed `CIContext` so it can keep up with live video on a background queue.
final class BokehCompositor {
    private let context: CIContext

    init() {
        context = CIContext(options: [.useSoftwareRenderer: false])
    }

    /// `blurRadius` is the adjustable "aperture" amount (0 = no effect, larger = shallower
    /// simulated depth of field).
    func composite(source: CIImage, mask: CIImage?, blurRadius: Double) -> CIImage {
        guard blurRadius > 0.1, let mask else { return source }

        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = source.clampedToExtent()
        blurFilter.radius = Float(blurRadius)
        let blurred = blurFilter.outputImage?.cropped(to: source.extent) ?? source

        let scaledMask = mask.transformed(by: CGAffineTransform(
            scaleX: source.extent.width / mask.extent.width,
            y: source.extent.height / mask.extent.height
        ))

        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = blurred
        blend.maskImage = scaledMask
        return blend.outputImage ?? source
    }

    /// Renders a composited `CIImage` into a freshly allocated pixel buffer matching the given
    /// pool, ready to hand to `AVAssetWriterInputPixelBufferAdaptor`.
    func render(_ image: CIImage, into pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        context.render(image, to: pixelBuffer)
        return pixelBuffer
    }
}
