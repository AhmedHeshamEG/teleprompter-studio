import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Composites a sharp foreground (masked by the segmentation result) over a blurred background,
/// i.e. a synthetic depth-of-field / "bokeh" effect. Runs entirely on the GPU via a Metal-backed
/// `CIContext` so it can keep up with live video on a background queue.
final class BokehCompositor {
    private let context: CIContext
    private let workingColorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        context = CIContext(options: [
            .useSoftwareRenderer: false,
            // Nothing here is reused between frames, and caching every intermediate of a live
            // video pipeline just grows memory until it gets evicted under pressure.
            .cacheIntermediates: false,
        ])
    }

    /// `blurRadius` is the adjustable "aperture" amount (0 = no effect, larger = shallower
    /// simulated depth of field), expressed against the *source* resolution.
    func composite(source: CIImage, mask: CIImage?, blurRadius: Double) -> CIImage {
        guard blurRadius > 0.1, let mask else { return source }

        let blurred = backgroundBlur(source, radius: blurRadius)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = source
        blend.backgroundImage = blurred
        blend.maskImage = subjectMask(mask, source: source, blurRadius: blurRadius)
        let composited = blend.outputImage ?? source

        return cinematicGrade(composited, extent: source.extent)
    }

    /// Background defocus.
    ///
    /// Two things separate this from the plain `CIGaussianBlur` it replaces, and they're the
    /// difference between "phone photo with a blur on it" and something that reads as a lens:
    ///
    /// 1. **Blur at a quarter scale.** Gaussian blur cost grows with both radius and pixel count.
    ///    Downscaling first, blurring with a proportionally smaller radius, then scaling back up
    ///    costs a fraction as much — and since the result is a smooth image by definition, the
    ///    upscale gives away nothing. This is what buys the frame rate back.
    /// 2. **Blur in a brightened (gamma-expanded) space.** Real out-of-focus highlights bloom into
    ///    bright discs; a linear average of pixels just turns them grey and muddy. Expanding the
    ///    highlights before the blur and pulling them back afterwards keeps specular points bright
    ///    as they spread, which is the actual visual signature of shallow depth of field.
    private func backgroundBlur(_ source: CIImage, radius: Double) -> CIImage {
        let downscale = 0.25
        let small = source
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))

        let expand = CIFilter.gammaAdjust()
        expand.inputImage = small
        expand.power = 2.2
        let expanded = expand.outputImage ?? small

        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = expanded.clampedToExtent()
        blurFilter.radius = Float(max(1, radius * downscale))
        let blurredSmall = blurFilter.outputImage ?? expanded

        let restore = CIFilter.gammaAdjust()
        restore.inputImage = blurredSmall
        restore.power = 1 / 2.2
        let restored = restore.outputImage ?? blurredSmall

        return restored
            .transformed(by: CGAffineTransform(scaleX: 1 / downscale, y: 1 / downscale))
            .cropped(to: source.extent)
    }

    /// Turns Vision's low-resolution, hard-edged cutout into a mask that can be blended without a
    /// visible halo: scale it to the frame, pull the edge *inward* slightly, then feather it.
    ///
    /// Pulling inward matters. Blending on the raw edge leaves a rim of sharp background clinging
    /// to the subject's outline — the giveaway that makes a fake blur look fake. Biasing the
    /// threshold so the mask sits just inside the silhouette hides that rim under the subject.
    private func subjectMask(_ mask: CIImage, source: CIImage, blurRadius: Double) -> CIImage {
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: source.extent.width / mask.extent.width,
            y: source.extent.height / mask.extent.height
        ))

        let tighten = CIFilter.colorControls()
        tighten.inputImage = scaled
        tighten.contrast = 1.6
        tighten.brightness = -0.06
        let tightened = tighten.outputImage ?? scaled

        let featherFilter = CIFilter.gaussianBlur()
        featherFilter.inputImage = tightened.clampedToExtent()
        featherFilter.radius = Float(maskFeatherRadius(for: blurRadius, height: source.extent.height))
        return featherFilter.outputImage?.cropped(to: source.extent) ?? tightened
    }

    /// Feather scales with the aperture blur (a stronger background blur makes a hard mask edge
    /// more obvious) *and* with frame height, so the softness looks identical whether it's being
    /// composited at preview resolution or at full recording resolution.
    private func maskFeatherRadius(for blurRadius: Double, height: CGFloat) -> Double {
        let relative = Double(height) * 0.006
        return min(max(relative, 2), max(3, blurRadius * 0.25))
    }

    /// A light filmic grade on top of the depth-of-field blur. Deliberately restrained: the
    /// previous values (saturation 1.2, contrast 1.14, a vignette at intensity 1.4) read as a
    /// heavy-handed photo filter rather than as a camera — crushed shadows, orange skin, a dark
    /// ring around the frame. This is a nudge, the way an actual film profile is.
    private func cinematicGrade(_ image: CIImage, extent: CGRect) -> CIImage {
        let colorFilter = CIFilter.colorControls()
        colorFilter.inputImage = image
        colorFilter.saturation = 1.06
        colorFilter.contrast = 1.04
        let graded = colorFilter.outputImage ?? image

        let vignette = CIFilter.vignette()
        vignette.inputImage = graded
        vignette.intensity = 0.45
        vignette.radius = Float(min(extent.width, extent.height) * 0.95)
        return vignette.outputImage?.cropped(to: extent) ?? graded
    }

    /// Renders a composited `CIImage` into a freshly allocated pixel buffer matching the given
    /// pool, ready to hand to `AVAssetWriterInputPixelBufferAdaptor` or an
    /// `AVSampleBufferDisplayLayer`.
    func render(_ image: CIImage, into pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        render(image, to: pixelBuffer)
        return pixelBuffer
    }

    /// Renders into an existing buffer, mapping the image's own extent onto the buffer's origin —
    /// composited images can carry a non-zero extent origin after transforms, and rendering
    /// without saying so silently offsets the frame.
    func render(_ image: CIImage, to pixelBuffer: CVPixelBuffer) {
        context.render(
            image,
            to: pixelBuffer,
            bounds: image.extent,
            colorSpace: workingColorSpace
        )
    }
}
