import AVFoundation
import CoreGraphics
import Foundation
import ObjectiveC.runtime

/// Runtime bridge to Apple's hardware **Cinematic Video capture** — the real iPhone Cinematic
/// mode, with the system's own rack focus, depth track and rendering — reached without the
/// compiler ever needing to know the API exists.
///
/// **Why it's done this way.** This project is built by a CI toolchain (`xtool` on a
/// GitHub-hosted macOS runner) whose iOS SDK does not declare `isCinematicVideoCaptureEnabled`,
/// `setCinematicVideoTrackingFocus(...)` or `AVCaptureDevice.CinematicVideoFocusMode`, so writing
/// them as ordinary Swift is a hard compile error — confirmed by a real build, see BUILD_NOTES.md.
/// But those members are Objective-C methods on classes that ship *in the OS on the device*, not
/// in the SDK we compile against, so the runtime on an iOS 26 iPhone has all of them. This file
/// reaches them through the Objective-C runtime, which compiles against any SDK and still gets the
/// genuine hardware path on hardware that has it.
///
/// **The API surface it targets** (WWDC25 "Capture cinematic video in your app", iOS 26):
///
/// | Where | Member |
/// |---|---|
/// | `AVCaptureDeviceInput` | `isCinematicVideoCaptureSupported`, `isCinematicVideoCaptureEnabled`, `simulatedAperture` |
/// | `AVCaptureDevice.Format` | `isCinematicVideoCaptureSupported`, `min`/`max`/`defaultSimulatedAperture` |
/// | `AVCaptureMetadataOutput` | `requiredMetadataObjectTypesForCinematicVideoCapture` |
/// | `AVCaptureDevice` | `setCinematicVideoTrackingFocus(detectedObjectID:focusMode:)`, `setCinematicVideoTrackingFocus(at:focusMode:)`, `setCinematicVideoFixedFocus(at:focusMode:)`, `cinematicVideoCaptureSceneMonitoringStatuses` |
/// | `AVMetadataObject` | `cinematicVideoFocusMode` |
///
/// **Nothing here is name-guessing.** Selectors are found by *scanning the class's actual method
/// list* for the cinematic members and classifying them by their Objective-C type encoding, so a
/// spelling that differs from the documented Swift signature (the `WithDetectedObjectID:` /
/// `AtPoint:` shapes the importer collapses) is found anyway, and an OS without the members finds
/// nothing and reports "not supported" instead of throwing.
enum CinematicVideoSupport {

    // MARK: Runtime lookup

    /// Every selector the class (and its superclasses, up to but excluding `NSObject`) implements,
    /// with its type encoding. Walking superclasses matters because AVFoundation puts some of
    /// these on a private base class rather than on the public leaf.
    private static func methods(of cls: AnyClass) -> [(selector: Selector, encoding: String)] {
        var result: [(Selector, String)] = []
        var current: AnyClass? = cls
        let stopAt = ObjectIdentifier(NSObject.self)
        while let klass = current, ObjectIdentifier(klass) != stopAt {
            var count: UInt32 = 0
            if let list = class_copyMethodList(klass, &count) {
                for index in 0..<Int(count) {
                    let method = list[index]
                    let selector = method_getName(method)
                    var encoding = ""
                    if let raw = method_getTypeEncoding(method) {
                        encoding = String(cString: raw)
                    }
                    result.append((selector, encoding))
                }
                free(list)
            }
            current = class_getSuperclass(klass)
        }
        return result
    }

    /// First selector on `cls` whose name contains `needle` (case-insensitively) and whose type
    /// encoding satisfies `matching`. Deterministic: candidates are sorted by name so the same
    /// selector is chosen on every launch.
    private static func findSelector(
        on cls: AnyClass,
        containing needle: String,
        matching: (String) -> Bool = { _ in true }
    ) -> Selector? {
        methods(of: cls)
            .filter { NSStringFromSelector($0.selector).lowercased().contains(needle.lowercased()) }
            .filter { matching($0.encoding) }
            .sorted { NSStringFromSelector($0.selector) < NSStringFromSelector($1.selector) }
            .first?
            .selector
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

    // MARK: Resolved members (looked up once)

    /// `-[AVCaptureDeviceInput setCinematicVideoCaptureEnabled:]`
    private static let inputEnableSetter: Selector? = {
        if let exact = findSelector(on: AVCaptureDeviceInput.self, containing: "setCinematicVideoCaptureEnabled:") {
            return exact
        }
        // Any `-setCinematicVideo…:` taking a single BOOL (`B`, or `c` in the older encoding).
        return findSelector(
            on: AVCaptureDeviceInput.self,
            containing: "setCinematicVideo",
            matching: { $0.hasSuffix("B16") || $0.hasSuffix("c16") }
        )
    }()

    /// `-[AVCaptureDeviceInput isCinematicVideoCaptureSupported]`
    private static let inputSupportGetter: Selector? = findSelector(
        on: AVCaptureDeviceInput.self,
        containing: "cinematicVideoCaptureSupported"
    )

    /// `-[AVCaptureDeviceInput setSimulatedAperture:]`
    private static let apertureSetter: Selector? = {
        if let exact = findSelector(on: AVCaptureDeviceInput.self, containing: "setSimulatedAperture:") {
            return exact
        }
        return findSelector(on: AVCaptureDeviceInput.self, containing: "simulatedAperture:")
    }()

    /// `-[AVCaptureDeviceFormat isCinematicVideoCaptureSupported]`. Resolved against the concrete
    /// class of a real format rather than `AVCaptureDevice.Format.self`, since AVFoundation
    /// returns a private subclass.
    private static func formatSupportSelector(for format: AVCaptureDevice.Format) -> Selector? {
        findSelector(on: type(of: format), containing: "cinematicVideoCaptureSupported")
            ?? findSelector(on: type(of: format), containing: "cinematicVideoSupported")
    }

    /// `-[AVCaptureMetadataOutput requiredMetadataObjectTypesForCinematicVideoCapture]`
    private static let requiredMetadataTypesGetter: Selector? = findSelector(
        on: AVCaptureMetadataOutput.self,
        containing: "requiredMetadataObjectTypesForCinematicVideo"
    )

    /// `-[AVCaptureDevice cinematicVideoCaptureSceneMonitoringStatuses]`
    private static let sceneMonitoringGetter: Selector? = findSelector(
        on: AVCaptureDevice.self,
        containing: "cinematicVideoCaptureSceneMonitoringStatuses"
    )

    /// Rack focus onto a detected subject by ID. Two integer arguments after the implicit
    /// `self`/`_cmd`, so the encoding carries no struct.
    private static let trackingFocusByIDSelector: Selector? = findSelector(
        on: AVCaptureDevice.self,
        containing: "cinematicVideoTrackingFocus",
        matching: { !$0.contains("{") }
    )

    /// Rack focus at an arbitrary point (the system finds a salient object there). Takes a
    /// `CGPoint`, which shows up in the encoding as `{CGPoint=dd}`.
    private static let trackingFocusAtPointSelector: Selector? = findSelector(
        on: AVCaptureDevice.self,
        containing: "cinematicVideoTrackingFocus",
        matching: { $0.contains("{CGPoint") }
    )

    /// Fixed (non-tracking) focus at a point — focus stays at that distance instead of following
    /// whatever was there.
    private static let fixedFocusAtPointSelector: Selector? = findSelector(
        on: AVCaptureDevice.self,
        containing: "cinematicVideoFixedFocus",
        matching: { $0.contains("{CGPoint") }
    )

    // MARK: Capability

    /// Whether this OS knows about Cinematic video capture at all. Cheap, and safe to call before
    /// the session has any device.
    static var isAvailableOnThisOS: Bool { inputEnableSetter != nil }

    /// Whether rack focus (tap a subject to pull focus onto it) can be driven on this OS.
    static var isFocusControlAvailable: Bool {
        trackingFocusAtPointSelector != nil || trackingFocusByIDSelector != nil
    }

    /// `true` when the *device* has at least one format the hardware can shoot Cinematic in.
    /// Cinematic is only offered on some cameras and only in some formats (its own constraints: a
    /// fixed set of resolutions and frame rates), which is exactly what this enumerates.
    static func isSupported(by device: AVCaptureDevice) -> Bool {
        guard isAvailableOnThisOS else { return false }
        return device.formats.contains(where: supportsCinematic)
    }

    static func supportsCinematic(_ format: AVCaptureDevice.Format) -> Bool {
        guard let selector = formatSupportSelector(for: format) else { return false }
        // KVC (not `perform`) because these return a primitive `BOOL`, which `perform` cannot read
        // correctly; `value(forKey:)` boxes it properly. The selector lookup above is what makes
        // the key safe — an unknown key would raise.
        return (format.value(forKey: keyPathName(for: NSStringFromSelector(selector))) as? Bool) ?? false
    }

    /// Whether the *input* — i.e. the device in its current session configuration — reports that
    /// Cinematic can be switched on right now. Stricter and more honest than the format scan,
    /// because it accounts for the rest of the session.
    static func isSupported(by input: AVCaptureDeviceInput) -> Bool {
        guard let selector = inputSupportGetter else { return false }
        return (input.value(forKey: keyPathName(for: NSStringFromSelector(selector))) as? Bool) ?? false
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

    // MARK: Enabling

    /// Turns Cinematic capture on/off for a device input. Must be called inside the session's
    /// `beginConfiguration`/`commitConfiguration`, on the session queue.
    ///
    /// Returns whether the flag actually took — the OS refuses silently if the active format
    /// can't do Cinematic, and the caller needs to know that so it can fall back rather than
    /// promise an effect that isn't running.
    @discardableResult
    static func setEnabled(_ enabled: Bool, on input: AVCaptureDeviceInput) -> Bool {
        guard let selector = inputEnableSetter else { return false }
        let key = keyPathName(for: NSStringFromSelector(selector))
        input.setValue(enabled, forKey: key)
        return (input.value(forKey: key) as? Bool) == enabled
    }

    static func isEnabled(on input: AVCaptureDeviceInput) -> Bool {
        guard let selector = inputEnableSetter else { return false }
        return (input.value(forKey: keyPathName(for: NSStringFromSelector(selector))) as? Bool) ?? false
    }

    // MARK: Aperture

    /// The f-stop range the active format renders Cinematic defocus across, and its default.
    /// Clamping to this matters: an out-of-range `simulatedAperture` is rejected, leaving the blur
    /// at whatever it was while the UI claims otherwise.
    static func apertureRange(for format: AVCaptureDevice.Format) -> (min: Float, max: Float, default: Float)? {
        let names = ["minSimulatedAperture", "maxSimulatedAperture", "defaultSimulatedAperture"]
        let values = names.compactMap { name -> Float? in
            guard format.responds(to: NSSelectorFromString(name)) else { return nil }
            return format.value(forKey: name) as? Float
        }
        guard values.count == 3, values[0] > 0, values[1] >= values[0] else { return nil }
        return (values[0], values[1], values[2])
    }

    /// Simulated aperture, in f-stops — the system's equivalent of the synthetic path's blur
    /// amount. Lower number = shallower depth of field. Clamped to the active format's supported
    /// range; silently ignored where unsupported.
    static func setSimulatedAperture(_ fNumber: Float, on input: AVCaptureDeviceInput) {
        guard let selector = apertureSetter else { return }
        var value = fNumber
        if let range = apertureRange(for: input.device.activeFormat) {
            value = min(max(fNumber, range.min), range.max)
        }
        input.setValue(value, forKey: keyPathName(for: NSStringFromSelector(selector)))
    }

    // MARK: Subject metadata

    /// The metadata object types Cinematic capture needs the session to be publishing in order to
    /// detect and track subjects. Without a metadata output configured with exactly these, the
    /// system has nothing to rack focus *between*: no subject rectangles, and focus-by-ID can't
    /// work at all.
    static func requiredMetadataObjectTypes(for output: AVCaptureMetadataOutput) -> [AVMetadataObject.ObjectType]? {
        guard let selector = requiredMetadataTypesGetter else { return nil }
        let key = keyPathName(for: NSStringFromSelector(selector))
        guard let raw = output.value(forKey: key) as? [String] else { return nil }
        return raw.map(AVMetadataObject.ObjectType.init(rawValue:))
    }

    /// The system's own read on whether the scene can actually sustain a Cinematic look — the
    /// "More light required" state the stock Camera app shows. Returned as raw status strings so
    /// this file stays free of symbols the SDK may not declare.
    static func sceneMonitoringStatuses(for device: AVCaptureDevice) -> Set<String> {
        guard let selector = sceneMonitoringGetter else { return [] }
        let key = keyPathName(for: NSStringFromSelector(selector))
        if let set = device.value(forKey: key) as? Set<String> { return set }
        if let array = device.value(forKey: key) as? [String] { return Set(array) }
        return []
    }

    /// `-[AVMetadataObject cinematicVideoFocusMode]` — whether Cinematic is currently holding
    /// focus on this subject, and how firmly. 0 when the OS doesn't publish it.
    static func focusMode(of metadataObject: AVMetadataObject) -> Int {
        let name = "cinematicVideoFocusMode"
        guard metadataObject.responds(to: NSSelectorFromString(name)) else { return 0 }
        return (metadataObject.value(forKey: name) as? Int) ?? 0
    }

    /// The subject ID carried by a metadata object, used to rack focus onto that exact subject.
    static func detectedObjectID(of metadataObject: AVMetadataObject) -> Int? {
        // `objectID` on the face/body/salient-object metadata subclasses.
        for name in ["objectID", "faceID"] where metadataObject.responds(to: NSSelectorFromString(name)) {
            if let value = metadataObject.value(forKey: name) as? Int { return value }
        }
        return nil
    }

    // MARK: Rack focus

    /// Objective-C call shapes for the focus methods. Both take primitives, which `perform(_:with:)`
    /// cannot pass (it boxes everything as an object), so the implementation pointer is called
    /// directly as a C function — the standard way to invoke a primitive-argument selector from
    /// Swift, and ABI-correct for both integers and a `CGPoint` in registers.
    private typealias FocusByIDIMP = @convention(c) (AnyObject, Selector, Int, Int) -> Void
    private typealias FocusAtPointIMP = @convention(c) (AnyObject, Selector, CGPoint, Int) -> Void

    /// Racks focus onto a subject the system has already detected. `focusMode` is
    /// `AVCaptureDevice.CinematicVideoFocusMode`: 0 none, 1 strong (keeps tracking this subject
    /// even when the algorithm would have chosen another), 2 weak (algorithm keeps control).
    ///
    /// Must be called with the device locked for configuration.
    @discardableResult
    static func setTrackingFocus(detectedObjectID objectID: Int, focusMode: Int, on device: AVCaptureDevice) -> Bool {
        guard let selector = trackingFocusByIDSelector, device.responds(to: selector) else { return false }
        let imp = unsafeBitCast(device.method(for: selector), to: FocusByIDIMP.self)
        imp(device, selector, objectID, focusMode)
        return true
    }

    /// Racks focus at a point: Cinematic searches for an interesting object there, makes it a
    /// tracked subject, and pulls focus onto it. `point` is in the normalized device coordinate
    /// space AVFoundation uses for focus (`captureDevicePointConverted(fromLayerPoint:)`).
    ///
    /// Must be called with the device locked for configuration.
    @discardableResult
    static func setTrackingFocus(at point: CGPoint, focusMode: Int, on device: AVCaptureDevice) -> Bool {
        guard let selector = trackingFocusAtPointSelector, device.responds(to: selector) else { return false }
        let imp = unsafeBitCast(device.method(for: selector), to: FocusAtPointIMP.self)
        imp(device, selector, point, focusMode)
        return true
    }

    /// Fixed focus at a point — the focus distance stays put instead of following the subject.
    @discardableResult
    static func setFixedFocus(at point: CGPoint, focusMode: Int, on device: AVCaptureDevice) -> Bool {
        guard let selector = fixedFocusAtPointSelector, device.responds(to: selector) else { return false }
        let imp = unsafeBitCast(device.method(for: selector), to: FocusAtPointIMP.self)
        imp(device, selector, point, focusMode)
        return true
    }

    // MARK: Stabilization

    /// `AVCaptureVideoStabilizationMode.cinematicExtendedEnhanced`, the mode Apple pairs with
    /// Cinematic capture. Referenced by raw value because the SDK this builds against may predate
    /// the case — and gated on the *active format* actually supporting it, since assigning a mode
    /// the format doesn't know is how you get an exception instead of smoother footage. An older
    /// OS supports neither raw value and simply keeps the mode it had.
    static func applyCinematicStabilization(to connection: AVCaptureConnection, device: AVCaptureDevice) {
        guard connection.isVideoStabilizationSupported else { return }
        let preferred = [5, 3] // cinematicExtendedEnhanced, then cinematicExtended
        for rawValue in preferred {
            guard let mode = AVCaptureVideoStabilizationMode(rawValue: rawValue),
                  device.activeFormat.isVideoStabilizationModeSupported(mode) else { continue }
            connection.preferredVideoStabilizationMode = mode
            return
        }
    }
}
