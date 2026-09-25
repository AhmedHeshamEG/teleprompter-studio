import AVFoundation
import CoreGraphics
import Foundation

/// Apple's hardware **Cinematic Video capture** (iOS 26, WWDC25 "Capture cinematic video in your
/// app") — the same Cinematic mode the stock Camera app shoots, with the system's own depth
/// rendering, rack focus and disparity track baked into the file.
///
/// Called as ordinary, compiler-checked API: the CI build uses Xcode 26 and the iOS 26 SDK (see
/// `.github/workflows/build-ipa.yml`). The app still deploys to iOS 17, so every member is behind
/// `#available(iOS 26.0, *)`; on an older OS the feature reports "not supported" and nothing runs.
///
/// There is no software stand-in. If the phone can't shoot Apple's Cinematic, the app says so and
/// leaves the camera alone.
enum CinematicVideoSupport {

    // MARK: Capability

    /// Whether this OS has the Cinematic Video API at all.
    static var isAvailableOnThisOS: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Whether rack focus (tap a subject to pull focus onto it) can be driven on this OS.
    static var isFocusControlAvailable: Bool { isAvailableOnThisOS }

    /// `true` when the device has at least one format the hardware can shoot Cinematic in.
    /// Only some cameras qualify — Apple's own list is the back Dual Wide camera and the front
    /// TrueDepth camera — and only in some formats (1080p/4K at 30fps).
    static func isSupported(by device: AVCaptureDevice) -> Bool {
        guard isAvailableOnThisOS else { return false }
        return device.formats.contains(where: supportsCinematic)
    }

    static func supportsCinematic(_ format: AVCaptureDevice.Format) -> Bool {
        if #available(iOS 26.0, *) { return format.isCinematicVideoCaptureSupported }
        return false
    }

    /// Whether the input, in the session's current configuration, can switch Cinematic on now.
    static func isSupported(by input: AVCaptureDeviceInput) -> Bool {
        if #available(iOS 26.0, *) { return input.isCinematicVideoCaptureSupported }
        return false
    }

    /// The camera to shoot Cinematic with for a given side: Apple's supported cameras first, then
    /// anything else on that side that turns out to have a Cinematic format. `nil` when this
    /// phone has none — the honest answer, not a cue to fake it.
    static func cinematicDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        guard isAvailableOnThisOS else { return nil }
        let preferred: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferred,
            mediaType: .video,
            position: position
        ).devices
        // `devices` isn't guaranteed to come back in the order asked for, so rank it ourselves.
        let ranked = devices.sorted { lhs, rhs in
            (preferred.firstIndex(of: lhs.deviceType) ?? .max) < (preferred.firstIndex(of: rhs.deviceType) ?? .max)
        }
        return ranked.first(where: isSupported(by:))
    }

    /// The Cinematic format for a requested resolution, preferring an exact match and otherwise
    /// taking the largest one the camera offers. Cinematic's formats are the system's choice, so
    /// insisting on 4K would turn the feature off on cameras that only do 1080p.
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

    // MARK: Enabling

    /// Turns Cinematic capture on/off for a device input. Must be called inside the session's
    /// `beginConfiguration`/`commitConfiguration`, on the session queue.
    ///
    /// Returns whether the flag actually took. Enabling is refused up front when the input says
    /// it can't: setting the flag on an unsupported configuration raises instead of failing.
    @discardableResult
    static func setEnabled(_ enabled: Bool, on input: AVCaptureDeviceInput) -> Bool {
        guard #available(iOS 26.0, *) else { return !enabled }
        if enabled {
            guard input.isCinematicVideoCaptureSupported else { return false }
        } else if !input.isCinematicVideoCaptureEnabled {
            return true
        }
        input.isCinematicVideoCaptureEnabled = enabled
        return input.isCinematicVideoCaptureEnabled == enabled
    }

    static func isEnabled(on input: AVCaptureDeviceInput) -> Bool {
        if #available(iOS 26.0, *) { return input.isCinematicVideoCaptureEnabled }
        return false
    }

    // MARK: Aperture

    /// The f-stop range the format renders Cinematic defocus across, and its default.
    static func apertureRange(for format: AVCaptureDevice.Format) -> (min: Float, max: Float, default: Float)? {
        guard #available(iOS 26.0, *), format.isCinematicVideoCaptureSupported else { return nil }
        let lower = format.minSimulatedAperture
        let upper = format.maxSimulatedAperture
        guard lower > 0, upper >= lower else { return nil }
        return (lower, upper, format.defaultSimulatedAperture)
    }

    /// Simulated aperture, in f-stops. Lower number = shallower depth of field. Clamped to the
    /// active format's range, since an out-of-range value is rejected.
    static func setSimulatedAperture(_ fNumber: Float, on input: AVCaptureDeviceInput) {
        guard #available(iOS 26.0, *), input.isCinematicVideoCaptureEnabled else { return }
        var value = fNumber
        if let range = apertureRange(for: input.device.activeFormat) {
            value = min(max(fNumber, range.min), range.max)
        }
        input.simulatedAperture = value
    }

    // MARK: Subject metadata

    /// The metadata object types Cinematic needs the session to publish. Apple requires the
    /// output's `metadataObjectTypes` to be *exactly* this list while Cinematic is on — anything
    /// else raises.
    static func requiredMetadataObjectTypes(for output: AVCaptureMetadataOutput) -> [AVMetadataObject.ObjectType]? {
        guard #available(iOS 26.0, *) else { return nil }
        return output.requiredMetadataObjectTypesForCinematicVideoCapture
    }

    /// Whether the system says the scene is too dark for a clean Cinematic effect — the same
    /// "More light required" state the stock Camera app shows.
    static func needsMoreLight(_ device: AVCaptureDevice) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return device.cinematicVideoCaptureSceneMonitoringStatuses.contains(.notEnoughLight)
    }

    /// Whether Cinematic is currently holding focus on this subject, and how firmly:
    /// 0 none, 1 strong, 2 weak.
    static func focusMode(of metadataObject: AVMetadataObject) -> Int {
        guard #available(iOS 26.0, *) else { return 0 }
        return Int(metadataObject.cinematicVideoFocusMode)
    }

    /// The subject ID carried by a metadata object, used to rack focus onto that exact subject.
    /// The ID lives on the concrete subclass (face, body, salient object), so it's read by name,
    /// guarded by `responds(to:)` so an object without one is simply skipped.
    static func detectedObjectID(of metadataObject: AVMetadataObject) -> Int? {
        for name in ["objectID", "faceID", "bodyID"] where metadataObject.responds(to: NSSelectorFromString(name)) {
            if let value = metadataObject.value(forKey: name) as? Int { return value }
        }
        return nil
    }

    // MARK: Rack focus

    @available(iOS 26.0, *)
    private static func platformFocusMode(_ rawValue: Int) -> AVCaptureDevice.CinematicVideoFocusMode {
        // `.none` is a query-only state — Apple says not to set it. "Auto" in the UI therefore
        // means a weak rack, which hands control back to the system's own subject choice.
        let mode = AVCaptureDevice.CinematicVideoFocusMode(rawValue: rawValue) ?? .strong
        return mode == .none ? .weak : mode
    }

    /// Racks focus onto a subject the system has already detected. Must be called with the
    /// device locked for configuration.
    @discardableResult
    static func setTrackingFocus(detectedObjectID objectID: Int, focusMode: Int, on device: AVCaptureDevice) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        device.setCinematicVideoTrackingFocus(detectedObjectID: objectID, focusMode: platformFocusMode(focusMode))
        return true
    }

    /// Racks focus at a point: Cinematic finds a salient object there, starts tracking it and
    /// pulls focus onto it. `point` is in normalized device coordinates. Device must be locked.
    @discardableResult
    static func setTrackingFocus(at point: CGPoint, focusMode: Int, on device: AVCaptureDevice) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        device.setCinematicVideoTrackingFocus(at: point, focusMode: platformFocusMode(focusMode))
        return true
    }

    /// Fixed focus at a point — the focus distance stays put instead of following the subject.
    @discardableResult
    static func setFixedFocus(at point: CGPoint, focusMode: Int, on device: AVCaptureDevice) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        device.setCinematicVideoFixedFocus(at: point, focusMode: platformFocusMode(focusMode))
        return true
    }

    // MARK: Stabilization

    /// `.cinematicExtendedEnhanced`, the mode Apple pairs with Cinematic capture, falling back to
    /// `.cinematicExtended` — gated on the active format supporting it, since assigning a mode the
    /// format doesn't know raises.
    static func applyCinematicStabilization(to connection: AVCaptureConnection, device: AVCaptureDevice) {
        guard connection.isVideoStabilizationSupported else { return }
        var modes: [AVCaptureVideoStabilizationMode] = [.cinematicExtended]
        if #available(iOS 18.0, *) { modes.insert(.cinematicExtendedEnhanced, at: 0) }
        for mode in modes where device.activeFormat.isVideoStabilizationModeSupported(mode) {
            connection.preferredVideoStabilizationMode = mode
            return
        }
    }
}
