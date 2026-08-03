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

        // Vision's segmentation mask is a hard-edged cutout; feathering it with a blur before
        // using it to blend gives a soft, natural falloff around hair/shoulders instead of the
        // harsh "cut-and-paste" edge a raw mask produces. Scales with the aperture amount so a
        // stronger blur (where a hard edge would be most obvious) gets the most feathering.
        let featherFilter = CIFilter.gaussianBlur()
        featherFilter.inputImage = scaledMask.clampedToExtent()
        featherFilter.radius = Float(maskFeatherRadius(for: blurRadius))
        let featheredMask = featherFilter.outputImage?.cropped(to: source.extent) ?? scaledMask

        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = blurred
        blend.maskImage = featheredMask
        let composited = blend.outputImage ?? source

        return cinematicGrade(composited, extent: source.extent)
    }

    /// Feather radius scales with the aperture blur itself: a stronger background blur makes a
    /// hard mask edge more visually obvious, so it needs proportionally more feathering to hide.
    private func maskFeatherRadius(for blurRadius: Double) -> Double {
        min(20, max(4, blurRadius * 0.4))
    }

    /// A light filmic grade (slightly richer contrast/saturation, gentle vignette) layered on
    /// top of the depth-of-field blur — the blur alone can look like a plain blurred phone photo;
    /// this is what actually reads as "cinematic" at a glance.
    private func cinematicGrade(_ image: CIImage, extent: CGRect) -> CIImage {
        let colorFilter = CIFilter.colorControls()
        colorFilter.inputImage = image
        colorFilter.saturation = 1.2
        colorFilter.contrast = 1.14
        colorFilter.brightness = -0.02
        let graded = colorFilter.outputImage ?? image

        let vignette = CIFilter.vignette()
        vignette.inputImage = graded
        vignette.intensity = 1.4
        vignette.radius = Float(min(extent.width, extent.height) * 0.65)
        return vignette.outputImage?.cropped(to: extent) ?? graded
    }

    /// Renders a composited `CIImage` for on-screen display (the live cinematic preview). Kept
    /// here rather than in the caller so the whole pipeline shares one Metal-backed `CIContext`
    /// instead of each consumer allocating its own GPU resources.
    func makeCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent)
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
