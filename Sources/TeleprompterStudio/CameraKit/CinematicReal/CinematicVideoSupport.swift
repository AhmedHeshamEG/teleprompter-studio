import AVFoundation
import Foundation

/// Runtime bridge to Apple's hardware **Cinematic Video capture** — the real iPhone Cinematic
/// mode, with the system's own rack focus, depth track and rendering — reached without the
/// compiler ever needing to know the API exists.
///
/// Why it's done this way: this project is built by a CI toolchain whose iOS SDK does not declare
/// `isCinematicVideoCaptureSupported` / `isCinematicVideoCaptureEnabled`, so writing them as
/// ordinary Swift is a hard compile error (confirmed by a real build — see BUILD_NOTES.md). But
/// those members are Objective-C properties on classes that ship *in the OS on the device*, not in
/// the SDK we compile against. Looking them up by selector at runtime therefore compiles anywhere
/// and still gets the genuine hardware path on a device whose iOS has it — which is the whole
/// point: real Cinematic where the phone can do it, the synthetic fallback where it can't.
///
/// Every lookup is guarded by `responds(to:)` before any KVC call, so on an OS without these
/// members nothing is invoked and nothing throws — the app just reports "not supported" and falls
/// back. Candidate name lists exist because the exact spelling can't be verified from this
/// environment; the first one the runtime recognises wins.
enum CinematicVideoSupport {
    /// Getter selectors on `AVCaptureDevice.Format` reporting whether that format can do Cinematic.
    private static let formatSupportSelectors = [
        "isCinematicVideoCaptureSupported",
        "isCinematicVideoSupported",
    ]

    /// Setter selectors on `AVCaptureDeviceInput` turning Cinematic capture on for the session.
    private static let inputEnableSelectors = [
        "setCinematicVideoCaptureEnabled:",
        "setCinematicVideoEnabled:",
    ]

    /// Setter for the simulated aperture (f-number) the system renders the defocus at.
    private static let apertureSelectors = [
        "setSimulatedAperture:",
        "setCinematicVideoSimulatedAperture:",
    ]

    /// Whether this OS knows about Cinematic capture at all. Cheap, and safe to call before the
    /// session has any device.
    static var isAvailableOnThisOS: Bool {
        resolvedInputEnableSelector != nil
    }

    private static var resolvedInputEnableSelector: Selector? {
        inputEnableSelectors
            .map(NSSelectorFromString)
            .first { AVCaptureDeviceInput.instancesRespond(to: $0) }
    }

    /// `true` when the *device* has at least one format the hardware can shoot Cinematic in.
    /// Cinematic is only offered on some cameras and only in some formats (its own constraints:
    /// a fixed set of resolutions and frame rates), which is exactly what this enumerates.
    static func isSupported(by device: AVCaptureDevice) -> Bool {
        guard isAvailableOnThisOS else { return false }
        return device.formats.contains(where: supportsCinematic)
    }

    static func supportsCinematic(_ format: AVCaptureDevice.Format) -> Bool {
        for name in formatSupportSelectors where format.responds(to: NSSelectorFromString(name)) {
            // KVC (not `perform`) because these return a primitive `BOOL`, which `perform` cannot
            // read correctly; `value(forKey:)` boxes it properly. The `responds` check above is
            // what makes the key safe — an unknown key would raise.
            if let value = format.value(forKey: keyPathName(for: name)) as? Bool {
                return value
            }
        }
        return false
    }

    /// The best Cinematic-capable format for a requested resolution/frame rate, preferring an
    /// exact match and otherwise taking the largest Cinematic format the camera offers. Returning
    /// *something* matters: Cinematic's supported resolutions are the system's choice, not ours,
    /// so insisting on 4K would simply turn the feature off on devices that only do 1080p.
    static func bestFormat(
        for device: AVCaptureDevice,
        resolution: CaptureResolution,
        fps: Double
    ) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter(supportsCinematic)
        guard !candidates.isEmpty else { return nil }

        let target = resolution.dimensions
        let exact = candidates.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dims.width) == target.width && Int(dims.height) == target.height
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        if let exact { return exact }

        return candidates.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }
    }

    /// Turns Cinematic capture on/off for a device input. Must be called inside the session's
    /// `beginConfiguration`/`commitConfiguration`, on the session queue.
    ///
    /// Returns whether the flag actually took — the OS refuses silently if the active format
    /// can't do Cinematic, and the caller needs to know that so it can fall back rather than
    /// promise an effect that isn't running.
    @discardableResult
    static func setEnabled(_ enabled: Bool, on input: AVCaptureDeviceInput) -> Bool {
        guard let selector = resolvedInputEnableSelector else { return false }
        let key = keyPathName(for: NSStringFromSelector(selector))
        input.setValue(enabled, forKey: key)
        return (input.value(forKey: key) as? Bool) == enabled
    }

    static func isEnabled(on input: AVCaptureDeviceInput) -> Bool {
        guard let selector = resolvedInputEnableSelector else { return false }
        return (input.value(forKey: keyPathName(for: NSStringFromSelector(selector))) as? Bool) ?? false
    }

    /// Simulated aperture, in f-stops — the system's equivalent of the synthetic path's blur
    /// amount. Lower number = shallower depth of field. Silently ignored where unsupported.
    static func setSimulatedAperture(_ fNumber: Float, on input: AVCaptureDeviceInput) {
        for name in apertureSelectors where input.responds(to: NSSelectorFromString(name)) {
            input.setValue(fNumber, forKey: keyPathName(for: name))
            return
        }
    }

    /// Converts a selector name into the KVC key that resolves to it:
    /// `setFooBar:` → `fooBar`, `isFooBar` → `fooBar`, `fooBar` → `fooBar`.
    private static func keyPathName(for selectorName: String) -> String {
        var name = selectorName
        if name.hasSuffix(":") { name.removeLast() }
        for prefix in ["set", "is"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }
}
