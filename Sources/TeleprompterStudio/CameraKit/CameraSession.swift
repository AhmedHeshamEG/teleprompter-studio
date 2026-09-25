import AVFoundation
import CoreImage
import Observation
import UIKit

enum CaptureResolution: String, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4k = "4K"

    var id: String { rawValue }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .hd1080: return (1920, 1080)
        case .uhd4k: return (3840, 2160)
        }
    }
}

/// Abstraction over the camera pipeline so the rest of the app (and previews/tests) don't need
/// a physical device. `AVCameraSession` is the real AVFoundation-backed implementation; any
/// future xtool-incompatible capability can be swapped in behind this protocol.
///
/// Deliberately NOT `@MainActor`: `AVCaptureSession` configuration must happen off the main
/// thread (Apple's own guidance), via `sessionQueue` below. Callers (always `CameraStudioViewModel`,
/// which is `@MainActor`) call these `async` methods with `await` and the implementation hops
/// back to the main actor itself before touching `@Observable` published state, so SwiftUI still
/// only ever observes changes made on the main thread.
protocol CameraSessionProviding: AnyObject {
    var captureSession: AVCaptureSession { get }
    var facing: CameraFacing { get }
    var isCinematicSupported: Bool { get }
    var isConfigured: Bool { get }

    func configure() async throws
    func start()
    func stop()
    func toggleFacing() async throws
    func setResolution(_ resolution: CaptureResolution, fps: Double) throws
    func setZoom(_ factor: CGFloat)
    func focus(at devicePoint: CGPoint)
    func setTorch(on: Bool)
    func setCinematicEnabled(_ enabled: Bool) throws
}

enum CameraSessionError: Error, LocalizedError {
    case noDeviceAvailable
    case configurationFailed(String)
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .noDeviceAvailable: return "No suitable camera was found on this device."
        case .configurationFailed(let reason): return "Camera configuration failed: \(reason)"
        case .notAuthorized: return "Camera access has not been authorized."
        }
    }
}

/// AVFoundation-backed camera session. All `AVCaptureSession`/`AVCaptureDevice` mutation happens
/// on `sessionQueue`; every write to an `@Observable` published property is explicitly bounced
/// to the main actor. `@unchecked Sendable` because the class's real thread-safety is enforced
/// by that serialized queue rather than by the compiler, which is the standard pattern for
/// wrapping `AVCaptureSession` (itself not `Sendable`) under Swift 6 strict concurrency.
@Observable
final class AVCameraSession: CameraSessionProviding, @unchecked Sendable {
    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "studio.camera.session")

    private(set) var facing: CameraFacing = .back
    private(set) var isConfigured = false
    /// Zoom, in the numbers the stock Camera app shows: 1× is the main wide lens, 0.5× the
    /// ultra-wide, 2×/3×/5× the telephoto. Not raw `videoZoomFactor` — on the multi-lens virtual
    /// cameras this app opens, a raw factor of 1.0 *is the ultra-wide*, which is why the camera
    /// used to open at 0.5×. See `zoomBaseline`.
    private(set) var currentZoom: CGFloat = 1.0
    private(set) var minZoom: CGFloat = 1.0
    private(set) var maxZoom: CGFloat = 1.0
    /// The lens stops worth a one-tap jump (e.g. 0.5, 1, 2, 3), in the same units.
    private(set) var zoomPresets: [CGFloat] = [1]

    /// Raw `videoZoomFactor` that corresponds to 1×: the first lens switch-over on a virtual
    /// camera that includes the ultra-wide, 1 otherwise. Session-queue state.
    private var zoomBaseline: CGFloat = 1
    /// Last zoom asked for, in display units. Kept across camera flips, format changes and
    /// Cinematic switching, all of which reset the device's own zoom. Session-queue state.
    private var requestedZoom: CGFloat = 1
    private(set) var torchOn: Bool = false

    /// Live "which way is up" angles from `AVCaptureDevice.RotationCoordinator`, kept in sync
    /// with the device's physical orientation (including landscape/upside-down) so the preview
    /// layer and every capture connection can rotate correctly without the app needing to track
    /// `UIDevice.orientation` itself. Read by `CameraPreviewView` (preview layer) and applied
    /// internally to `videoDataOutput`/`movieFileOutput` connections on every change.
    private(set) var previewRotationAngle: CGFloat = 90
    private(set) var captureRotationAngle: CGFloat = 90

    /// Whether the active connections are currently mirrored. Published so `CameraPreviewView`
    /// can apply the exact same mirroring to its own preview-layer connection — previously the
    /// preview layer relied on `AVCaptureVideoPreviewLayer`'s undocumented default auto-mirror
    /// behavior while `videoDataOutput` was mirrored explicitly and `movieFileOutput` wasn't
    /// touched at all, so the three connections could disagree about whether the image should be
    /// flipped. This is now the single source of truth all three connections apply identically.
    private(set) var isMirrored = false
    /// Front camera mirrors by default (selfie-style), matching every stock camera app.
    var mirrorFrontCamera = true

    /// The live preview layer, set once by `CameraPreviewView.makeUIView`. Rotation/mirroring are
    /// applied to it directly from `sessionQueue` the moment they're computed (see
    /// `applyRotationAngles`/`applyMirroring`) instead of only through the `previewRotationAngle`/
    /// `isMirrored` `@Observable` properties read inside `CameraPreviewView.updateUIView`.
    /// Property reads that only ever happen inside a `UIViewRepresentable`'s `updateUIView` (never
    /// inside a SwiftUI `View.body`) are not reliably tracked by the Observation framework, so
    /// `updateUIView` was not consistently re-invoked when the device rotated or facing changed —
    /// the preview could get stuck showing the sensor's native (landscape) orientation inside a
    /// portrait frame, or vice versa, and mirroring could likewise get stuck. This direct
    /// reference is the fix: it guarantees every rotation/mirror update reaches the actual
    /// `AVCaptureConnection` regardless of whether SwiftUI re-renders anything.
    weak var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            sessionQueue.async { [weak self] in self?.syncPreviewLayerNow() }
        }
    }

    /// Re-applies the last-known rotation angle and mirror state directly to `previewLayer`'s
    /// connection. Called whenever `previewLayer` is (re)attached, so a layer that attaches after
    /// the session already configured (a real race between SwiftUI creating the `UIView` and
    /// `configure()` finishing) still ends up correctly oriented on its very first frame.
    private func syncPreviewLayerNow() {
        guard let previewLayer, let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(lastPreviewAngle) {
            connection.videoRotationAngle = lastPreviewAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = lastMirrored
        }
    }

    /// Last-known values applied directly to `previewLayer`'s connection from `sessionQueue`;
    /// separate from the `@Observable` `previewRotationAngle`/`isMirrored` (which exist for any
    /// other UI that wants to read them) so `syncPreviewLayerNow()` never has to hop to main.
    private var lastPreviewAngle: CGFloat = 90
    private var lastCaptureAngle: CGFloat = 90
    private var lastMirrored = false

    /// Unique ID of the currently-selected audio input device (built-in mic, wired/Bluetooth
    /// headset mic, or an external USB/Lightning mic), or `nil` if none is attached. `nil` passed
    /// to `setAudioDevice` means "use the system default".
    private(set) var selectedAudioDeviceID: String?
    private var preferredAudioDeviceID: String?

    /// Fired (off the main thread) with `(previewAngle, captureAngle)` whenever either changes.
    /// Anything drawing processed capture frames *over* the preview needs the difference between
    /// the two: frames from `videoDataOutput` are rotated for capture, the preview layer is rotated
    /// for the interface. They agree while the interface follows the device, and diverge the moment
    /// rotation is locked and the phone is turned.
    var onRotationAnglesChanged: ((CGFloat, CGFloat) -> Void)?

    /// Frames delegate for the Companion live-preview stream to hook into.
    weak var videoDataDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    let movieFileOutput = AVCaptureMovieFileOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()
    private let dataOutputQueue = DispatchQueue(label: "studio.camera.dataOutput")

    /// Whether the raw-frame tap (`videoDataOutput`) is attached to the session. **Off by
    /// default.** It is only needed by the Companion preview stream, but it used to be attached
    /// unconditionally, so every ordinary session paid for a second
    /// full-rate video path (and a per-frame delegate hop) that nothing was reading. On a 1080p60
    /// session that is a large, permanent tax on memory bandwidth and thermals, which is exactly
    /// what "the whole app feels laggy / buttons need several taps" looks like from the outside:
    /// the main thread competing with a capture pipeline that is doing pointless work.
    private var dataOutputsEnabled = false

    /// Whether **Apple's own Cinematic Video capture** can run on the current side (back/front):
    /// the OS has the API and a camera on that side has a Cinematic-capable format. That camera
    /// isn't necessarily the one in use — Cinematic runs on the Dual Wide / TrueDepth camera, and
    /// the session swaps to it when the effect is switched on.
    ///
    /// Resolved once per configuration (see `configureSessionSync`) rather than computed on
    /// demand, because it's read from SwiftUI bodies and enumerating every camera format is not
    /// something to do during a view update. The check itself is a runtime one — see
    /// `CinematicVideoSupport` for why the API can't simply be called in source.
    private(set) var isCinematicSupported = false

    /// Whether Cinematic capture is currently switched on *and the OS accepted it*. This is the
    /// honest answer, not the requested one: if the camera can't do it, this stays `false` and the
    /// app says so instead of pretending.
    private(set) var isCinematicActive = false

    /// Requested Cinematic state, applied on the session queue and re-applied whenever the format
    /// changes underneath it (resolution changes, camera flips).
    private var wantsCinematic = false

    /// Why the hardware Cinematic path isn't running, when it was asked for and didn't engage.
    /// Published so the UI can say *which* wall it hit instead of silently showing the simulated
    /// badge and leaving the user to guess whether their phone can do this at all.
    private(set) var cinematicUnavailableReason: String?

    /// The system's own scene assessment while Cinematic runs — non-nil when it wants more light,
    /// the same warning the stock Camera app puts on screen. Sampled on the session queue while
    /// the effect is active (one property read, a couple of times a second).
    private(set) var cinematicSceneWarning: String?

    /// Subject metadata output, attached **only** while hardware Cinematic is running. Cinematic
    /// needs the session to publish the subject types it names in
    /// `requiredMetadataObjectTypesForCinematicVideoCapture` — without them the system has no
    /// tracked subjects, so there is nothing to rack focus between and no rectangles to draw.
    let metadataOutput = AVCaptureMetadataOutput()
    private var metadataOutputAttached = false

    /// Receives detected-subject metadata while Cinematic is on. Set by `CameraStudioViewModel`.
    weak var cinematicMetadataDelegate: AVCaptureMetadataOutputObjectsDelegate?

    /// `AVCaptureDevice.CinematicVideoFocusMode` raw value used for taps: 1 = strong (hold this
    /// subject), 2 = weak (let the algorithm keep control). Set from Studio Settings.
    var cinematicFocusModeRawValue: Int = 1

    private var sceneMonitorTimer: DispatchSourceTimer?

    /// Last aperture the user asked for, re-applied whenever Cinematic (re-)engages.
    private var requestedAperture: Double = 2.8

    /// Set when the camera couldn't honour the requested resolution/frame rate and something else
    /// was used instead; `nil` when the request was met exactly. Read by Studio Settings and shown
    /// as a badge over the preview.
    var captureFallbackNote: String?

    /// Last requested capture settings, so Cinematic format selection and a later
    /// `applyResolution` agree about what the user asked for.
    private var lastResolution: CaptureResolution = .uhd4k
    private var lastFPS: Double = 30

    func configure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configureSessionSync(facing: .back)
                    DispatchQueue.main.async {
                        self.isConfigured = true
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureSessionSync(facing: CameraFacing) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high

        // Remove any prior inputs/outputs (used when toggling facing).
        for input in captureSession.inputs { captureSession.removeInput(input) }
        for output in captureSession.outputs { captureSession.removeOutput(output) }
        // The metadata output went with them, so the bookkeeping has to agree — otherwise a
        // camera flip leaves Cinematic believing it still has a subject-detection output attached
        // and quietly loses subject tracking for the rest of the session.
        metadataOutputAttached = false
        stopSceneMonitoring()

        // Cinematic only runs on specific cameras (back Dual Wide, front TrueDepth) — the Triple
        // camera this app otherwise prefers has no Cinematic formats, which is why switching it on
        // used to land on the fake effect. Pick the camera for the job.
        let position: AVCaptureDevice.Position = facing == .back ? .back : .front
        let cinematicDevice = CinematicVideoSupport.cinematicDevice(for: position)
        let chosenDevice = wantsCinematic ? (cinematicDevice ?? Self.device(for: facing)) : Self.device(for: facing)
        guard let videoDevice = chosenDevice else {
            throw CameraSessionError.noDeviceAvailable
        }
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard captureSession.canAddInput(videoInput) else {
            throw CameraSessionError.configurationFailed("Cannot add video input")
        }
        captureSession.addInput(videoInput)
        videoDeviceInput = videoInput

        let resolvedAudioDevice = preferredAudioDeviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        if let audioDevice = resolvedAudioDevice {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
                audioDeviceInput = audioInput
            }
        }
        DispatchQueue.main.async { self.selectedAudioDeviceID = resolvedAudioDevice?.uniqueID }

        if captureSession.canAddOutput(movieFileOutput) {
            captureSession.addOutput(movieFileOutput)
        }

        if dataOutputsEnabled {
            attachDataOutputsSync()
        }

        applyMirroring(facing: facing)
        setUpRotationCoordinator(for: videoDevice)

        // Before Cinematic is applied: that path re-applies zoom too, and needs the right baseline.
        zoomBaseline = Self.zoomBaseline(for: videoDevice)

        let cinematicSupported = cinematicDevice != nil
        DispatchQueue.main.async {
            self.facing = facing
            self.isCinematicSupported = cinematicSupported
        }

        // Flipping the camera rebuilds the input, so a Cinematic session has to be re-established
        // on the new device rather than silently dropping to a plain one.
        if wantsCinematic, CinematicVideoSupport.isSupported(by: videoDevice) {
            applyCinematicSync(true, device: videoDevice, input: videoInput)
        } else if wantsCinematic {
            failCinematic(CinematicVideoSupport.isAvailableOnThisOS
                ? "This iPhone's \(facing == .back ? "back" : "front") camera can't shoot Apple Cinematic."
                : "Apple Cinematic needs iOS 26 or later.")
        }
        applyZoomSync(device: videoDevice)
    }

    // MARK: Zoom

    /// Raw zoom factor that shows what the stock Camera app calls 1×.
    private static func zoomBaseline(for device: AVCaptureDevice) -> CGFloat {
        guard device.isVirtualDevice,
              device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
              let first = device.virtualDeviceSwitchOverVideoZoomFactors.first
        else { return 1 }
        return CGFloat(truncating: first)
    }

    /// Pushes `requestedZoom` onto the device, clamped to what it can do right now, and publishes
    /// the result. Must run on `sessionQueue`. Called after anything that resets the device's
    /// zoom — a new device, a new format, Cinematic switching on or off.
    private func applyZoomSync(device: AVCaptureDevice) {
        let baseline = zoomBaseline
        let lowest = device.minAvailableVideoZoomFactor
        // Past 10× digital zoom is mush on a talking head.
        let highest = max(lowest, min(device.maxAvailableVideoZoomFactor, baseline * 10))
        let factor = max(lowest, min(requestedZoom * baseline, highest))
        if abs(device.videoZoomFactor - factor) > 0.001, (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }

        var presets: [CGFloat] = []
        if lowest < baseline - 0.01 { presets.append(lowest / baseline) }
        presets.append(1)
        for switchOver in device.virtualDeviceSwitchOverVideoZoomFactors {
            let stop = CGFloat(truncating: switchOver) / baseline
            if stop > 1.01, stop * baseline <= highest { presets.append(stop) }
        }
        // A 2× crop, like the stock app offers even on phones with no 2× lens.
        if !presets.contains(where: { abs($0 - 2) < 0.05 }), 2 * baseline <= highest { presets.append(2) }
        presets.sort()

        let display = factor / baseline
        let minDisplay = lowest / baseline
        let maxDisplay = highest / baseline
        DispatchQueue.main.async {
            self.currentZoom = display
            self.minZoom = minDisplay
            self.maxZoom = maxDisplay
            if self.zoomPresets != presets { self.zoomPresets = presets }
        }
    }

    /// Turns Apple's Cinematic Video capture on/off. Must run on `sessionQueue`; the caller owns
    /// the `beginConfiguration`/`commitConfiguration` pair *or* this is called from inside
    /// `configureSessionSync`, which already holds one.
    ///
    /// Order matters: Cinematic only engages on a format that supports it, so the format is
    /// selected first and the flag set afterwards. Frame rate is left to whatever the Cinematic
    /// format allows — those constraints are the system's, and overriding them is what makes the
    /// flag get quietly refused.
    private func applyCinematicSync(_ enabled: Bool, device: AVCaptureDevice, input: AVCaptureDeviceInput) {
        guard enabled else {
            CinematicVideoSupport.setEnabled(false, on: input)
            detachMetadataOutputSync()
            stopSceneMonitoring()
            DispatchQueue.main.async {
                self.isCinematicActive = false
                self.cinematicUnavailableReason = nil
                self.cinematicSceneWarning = nil
            }
            return
        }

        guard CinematicVideoSupport.isAvailableOnThisOS else {
            failCinematic("Apple Cinematic needs iOS 26 or later.")
            return
        }
        guard let format = CinematicVideoSupport.bestFormat(for: device, resolution: lastResolution, fps: 30) else {
            failCinematic("This camera has no Cinematic format.")
            return
        }
        if device.activeFormat != format {
            guard (try? device.lockForConfiguration()) != nil else {
                failCinematic("The camera was busy and wouldn't switch to a Cinematic format.")
                return
            }
            device.activeFormat = format
            device.unlockForConfiguration()
        }

        let accepted = CinematicVideoSupport.setEnabled(true, on: input)
        guard accepted else {
            // Leave the session in a clean non-Cinematic state rather than half-configured.
            CinematicVideoSupport.setEnabled(false, on: input)
            failCinematic("iOS declined Cinematic for this camera setup.")
            return
        }

        // Order matters: the required metadata types are only meaningful once Cinematic is on.
        attachMetadataOutputSync()
        if let connection = movieFileOutput.connection(with: .video) {
            CinematicVideoSupport.applyCinematicStabilization(to: connection, device: device)
        }
        CinematicVideoSupport.setSimulatedAperture(Float(requestedAperture), on: input)
        startSceneMonitoring(device: device)
        // The Cinematic format switch reset the zoom; put 1× (or whatever was chosen) back.
        applyZoomSync(device: device)

        DispatchQueue.main.async {
            self.isCinematicActive = true
            self.cinematicUnavailableReason = nil
        }
    }

    /// Records why the hardware path didn't engage and leaves `isCinematicActive` false, which is
    /// what makes `CameraStudioViewModel` switch the Cinematic button back off and say why.
    private func failCinematic(_ reason: String) {
        DispatchQueue.main.async {
            self.isCinematicActive = false
            self.cinematicUnavailableReason = reason
        }
    }

    /// Adds the subject-metadata output Cinematic needs and asks the system which object types it
    /// requires. Must run on `sessionQueue`; the caller owns the configuration transaction.
    private func attachMetadataOutputSync() {
        if !metadataOutputAttached {
            guard captureSession.canAddOutput(metadataOutput) else { return }
            captureSession.addOutput(metadataOutput)
            metadataOutputAttached = true
        }
        metadataOutput.setMetadataObjectsDelegate(cinematicMetadataDelegate, queue: dataOutputQueue)
        if let types = CinematicVideoSupport.requiredMetadataObjectTypes(for: metadataOutput) {
            // Exactly the required list, as Apple's sample does: while Cinematic is on, any other
            // set of types raises.
            metadataOutput.metadataObjectTypes = types
        }
    }

    private func detachMetadataOutputSync() {
        guard metadataOutputAttached else { return }
        metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
        captureSession.removeOutput(metadataOutput)
        metadataOutputAttached = false
    }

    /// Polls the system's Cinematic scene assessment (currently only "not enough light") while the
    /// effect runs. One property read every 1.5s on the session queue — cheap enough to be honest
    /// with, and it stops the moment Cinematic does.
    private func startSceneMonitoring(device: AVCaptureDevice) {
        stopSceneMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self, weak device] in
            guard let self, let device else { return }
            let warning = CinematicVideoSupport.needsMoreLight(device) ? "More light needed for a clean Cinematic effect." : nil
            DispatchQueue.main.async {
                if self.cinematicSceneWarning != warning { self.cinematicSceneWarning = warning }
            }
        }
        timer.resume()
        sceneMonitorTimer = timer
    }

    private func stopSceneMonitoring() {
        sceneMonitorTimer?.cancel()
        sceneMonitorTimer = nil
    }

    /// Racks focus the Cinematic way: the system finds a subject at `devicePoint`, starts tracking
    /// it, and pulls focus onto it with the configured focus style. Returns `false` when the
    /// hardware path isn't running or the OS has no such control, so the caller can fall back to
    /// ordinary autofocus rather than appearing to do nothing.
    @discardableResult
    func setCinematicFocus(at devicePoint: CGPoint) -> Bool {
        guard isCinematicActive, CinematicVideoSupport.isFocusControlAvailable else { return false }
        // Applied on the session queue like every other device mutation. Deliberately not
        // `sync`: this is called straight from a tap on the preview, and blocking the main thread
        // behind a session that may be mid-reconfiguration is how a camera UI drops frames.
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            CinematicVideoSupport.setTrackingFocus(
                at: devicePoint,
                focusMode: self.cinematicFocusModeRawValue,
                on: device
            )
            device.unlockForConfiguration()
        }
        return true
    }

    /// Racks focus onto a subject the system already reported in its metadata — tapping one of the
    /// detected-subject rectangles, rather than a bare point.
    @discardableResult
    func setCinematicFocus(detectedObjectID objectID: Int) -> Bool {
        guard isCinematicActive, CinematicVideoSupport.isFocusControlAvailable else { return false }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            CinematicVideoSupport.setTrackingFocus(
                detectedObjectID: objectID,
                focusMode: self.cinematicFocusModeRawValue,
                on: device
            )
            device.unlockForConfiguration()
        }
        return true
    }

    /// Attaches/detaches the raw-frame outputs on the fly. Called by `CameraStudioViewModel` when
    /// something actually starts needing frames (cinematic mode turned on, a Companion device
    /// connected) and again when it stops. Idempotent and safe before `configure()` — in that case
    /// it just records the preference, and `configureSessionSync` honours it.
    func setDataOutputsEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.dataOutputsEnabled != enabled else { return }
            self.dataOutputsEnabled = enabled
            guard self.videoDeviceInput != nil else { return } // not configured yet
            self.captureSession.beginConfiguration()
            if enabled {
                self.attachDataOutputsSync()
            } else {
                self.captureSession.removeOutput(self.videoDataOutput)
            }
            self.captureSession.commitConfiguration()
            if enabled {
                // Freshly added outputs come with fresh connections, so the current rotation and
                // mirroring have to be pushed onto them or recorded frames come out sideways.
                self.applyMirroring(facing: self.facing)
                self.applyRotationAngles(preview: nil, capture: self.lastCaptureAngle)
            }
        }
    }

    /// Must be called on `sessionQueue`, inside a configuration transaction.
    private func attachDataOutputsSync() {
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(videoDataDelegate, queue: dataOutputQueue)
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
        }
    }

    /// Applies mirroring explicitly to `videoDataOutput` and `movieFileOutput`'s connections
    /// (turning off `automaticallyAdjustsVideoMirroring` first — leaving it on while also setting
    /// `isVideoMirrored` directly is invalid and AVFoundation ignores the manual value, which is
    /// why the old front-camera-only override here had no reliable effect). Republishes
    /// `isMirrored` so `CameraPreviewView` mirrors its own preview layer to match, keeping all
    /// three connections in agreement.
    private func applyMirroring(facing: CameraFacing) {
        let shouldMirror = facing == .front && mirrorFrontCamera
        for output in [videoDataOutput as AVCaptureOutput, movieFileOutput as AVCaptureOutput] {
            guard let connection = output.connection(with: .video), connection.isVideoMirroringSupported else { continue }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = shouldMirror
        }
        lastMirrored = shouldMirror
        syncPreviewLayerNow()
        DispatchQueue.main.async { self.isMirrored = shouldMirror }
    }

    /// Drives live rotation for the preview layer and every capture connection off
    /// `AVCaptureDevice.RotationCoordinator`, which tracks the device's physical orientation
    /// (including landscape and upside-down) via the accelerometer — the modern replacement for
    /// manually mapping `UIDeviceOrientation` to a fixed angle. Re-created whenever the active
    /// device changes (e.g. front/back toggle) since the coordinator is bound to one device.
    private func setUpRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        applyRotationAngles(
            preview: coordinator.videoRotationAngleForHorizonLevelPreview,
            capture: coordinator.videoRotationAngleForHorizonLevelCapture
        )

        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
            guard let self, let angle = change.newValue else { return }
            self.sessionQueue.async { self.applyRotationAngles(preview: angle, capture: nil) }
        })
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, change in
            guard let self, let angle = change.newValue else { return }
            self.sessionQueue.async { self.applyRotationAngles(preview: nil, capture: angle) }
        })
    }

    /// Applies rotation angles to the relevant connections. Must run on `sessionQueue` (KVO
    /// callbacks land on an arbitrary thread). `preview` is republished to the main actor for
    /// `CameraPreviewView` to apply to its own `AVCaptureVideoPreviewLayer` connection.
    private func applyRotationAngles(preview: CGFloat?, capture: CGFloat?) {
        if let capture {
            lastCaptureAngle = capture
            for output in [videoDataOutput as AVCaptureOutput, movieFileOutput as AVCaptureOutput] {
                guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(capture) else { continue }
                connection.videoRotationAngle = capture
            }
            DispatchQueue.main.async { self.captureRotationAngle = capture }
        }
        if let preview {
            lastPreviewAngle = preview
            syncPreviewLayerNow()
            DispatchQueue.main.async { self.previewRotationAngle = preview }
        }
        onRotationAnglesChanged?(lastPreviewAngle, lastCaptureAngle)
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    func stop() {
        stopSceneMonitoring()
        sessionQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    func toggleFacing() async throws {
        let newFacing: CameraFacing = facing == .back ? .front : .back
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configureSessionSync(facing: newFacing)
                    DispatchQueue.main.async { continuation.resume() }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Every currently-attached audio input device the user could record with: built-in mic,
    /// wired/Bluetooth headset mics, and external USB/Lightning mics (e.g. a lav or shotgun mic).
    nonisolated static func availableAudioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    }

    /// Switches the active audio input. Reconfigures the whole session (same path as
    /// `toggleFacing`) since that's the simplest correct way to safely swap an `AVCaptureInput`
    /// on this session — call it from Settings, not mid-recording.
    func setAudioDevice(_ device: AVCaptureDevice?) async throws {
        preferredAudioDeviceID = device?.uniqueID
        let currentFacing = facing
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configureSessionSync(facing: currentFacing)
                    DispatchQueue.main.async { continuation.resume() }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Best-effort, non-throwing, correctly-sequenced version of `setResolution`.
    ///
    /// `setResolution` mutates `AVCaptureDevice.activeFormat` from whatever thread calls it (in
    /// practice the main actor) and outside any `beginConfiguration`/`commitConfiguration` pair.
    /// Swapping the active format that way while `movieFileOutput` is attached can drop the
    /// output's connections — after which `startRecording` is a silent no-op and the record button
    /// appears dead. This does it on `sessionQueue`, inside a configuration transaction, and
    /// leaves the session untouched when no matching format exists.
    func applyResolution(_ resolution: CaptureResolution, fps: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let input = self.videoDeviceInput else { return }
            let device = input.device
            self.lastResolution = resolution
            self.lastFPS = fps
            // While Cinematic is running, the *set of usable formats is the system's to decide*.
            // Picking a plain format here would silently switch Cinematic off, which is precisely
            // how a capture mode ends up looking like it "doesn't do anything".
            if self.wantsCinematic, self.isCinematicActive {
                self.captureSession.beginConfiguration()
                self.applyCinematicSync(true, device: device, input: input)
                self.captureSession.commitConfiguration()
                self.applyMirroring(facing: self.facing)
                self.applyRotationAngles(preview: self.lastPreviewAngle, capture: self.lastCaptureAngle)
                return
            }
            // 4K/60 (and 4K at all, on some cameras — the ultra-wide and most front cameras cap
            // lower) simply doesn't exist as a format everywhere. Asking for it and silently doing
            // nothing left the app *claiming* 4K in Settings while recording whatever preset the
            // session had negotiated, which is the worst of the three possible outcomes. Walk down
            // to the nearest thing the camera really has, and say what happened.
            guard let (format, chosen, chosenFPS) = Self.resolveFormat(
                for: device,
                resolution: resolution,
                fps: fps
            ) else { return }
            self.captureSession.beginConfiguration()
            defer { self.captureSession.commitConfiguration() }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: Int32(chosenFPS))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                return
            }
            self.reportCaptureFallback(
                requested: resolution,
                requestedFPS: fps,
                actual: chosen,
                actualFPS: chosenFPS
            )
            // A new format resets the zoom factor, which would drop a 1× camera back to 0.5×.
            self.applyZoomSync(device: device)
            // Format changes rebuild connections, so rotation and mirroring have to be re-applied.
            self.applyMirroring(facing: self.facing)
            self.applyRotationAngles(preview: self.lastPreviewAngle, capture: self.lastCaptureAngle)
        }
    }

    /// The best format for what was asked, then for the same resolution at 30fps, then for 1080p,
    /// in that order — resolution is what people notice, frame rate is what they can live with.
    private static func resolveFormat(
        for device: AVCaptureDevice,
        resolution: CaptureResolution,
        fps: Double
    ) -> (AVCaptureDevice.Format, CaptureResolution, Double)? {
        var attempts: [(CaptureResolution, Double)] = [(resolution, fps)]
        if fps > 30 { attempts.append((resolution, 30)) }
        if resolution != .hd1080 {
            attempts.append((.hd1080, fps))
            if fps > 30 { attempts.append((.hd1080, 30)) }
        }
        for (candidateResolution, candidateFPS) in attempts {
            if let format = bestFormat(for: device, resolution: candidateResolution, fps: candidateFPS) {
                return (format, candidateResolution, candidateFPS)
            }
        }
        return nil
    }

    /// Tells whoever is listening that the camera landed somewhere other than what was asked for —
    /// once per distinct outcome, not once per reconfiguration.
    private func reportCaptureFallback(
        requested: CaptureResolution,
        requestedFPS: Double,
        actual: CaptureResolution,
        actualFPS: Double
    ) {
        let note: String?
        if requested == actual, requestedFPS == actualFPS {
            note = nil
        } else {
            note = "This camera has no \(requested.rawValue) @ \(Int(requestedFPS))fps format. Recording \(actual.rawValue) @ \(Int(actualFPS))fps."
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureFallbackNote != note else { return }
            self.captureFallbackNote = note
        }
    }

    private static func bestFormat(for device: AVCaptureDevice, resolution: CaptureResolution, fps: Double) -> AVCaptureDevice.Format? {
        let target = resolution.dimensions
        return device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dims.width) == target.width && Int(dims.height) == target.height
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
    }

    func setResolution(_ resolution: CaptureResolution, fps: Double) throws {
        guard let device = videoDeviceInput?.device else { throw CameraSessionError.noDeviceAvailable }
        let target = resolution.dimensions

        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dims.width) == target.width && Int(dims.height) == target.height
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        guard let bestFormat = candidates.first else {
            throw CameraSessionError.configurationFailed("No format for \(resolution.rawValue) @ \(fps)fps")
        }

        try device.lockForConfiguration()
        device.activeFormat = bestFormat
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
        device.unlockForConfiguration()
    }

    /// Sets zoom in display units (1 = 1×, 0.5 = ultra-wide). Applied on the session queue like
    /// every other device change; `currentZoom` follows once it has taken.
    func setZoom(_ factor: CGFloat) {
        let target = max(minZoom, min(factor, maxZoom))
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            self.requestedZoom = target
            self.applyZoomSync(device: device)
        }
    }

    func focus(at devicePoint: CGPoint) {
        guard let device = videoDeviceInput?.device else { return }
        try? device.lockForConfiguration()
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose
        }
        device.unlockForConfiguration()
    }

    func setTorch(on: Bool) {
        guard let device = videoDeviceInput?.device, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        torchOn = on
    }

    /// Switches Apple's Cinematic Video capture on or off. Asynchronous by nature (it reconfigures
    /// the running session), so success is reported through `isCinematicActive` rather than by
    /// returning — callers watch that (and `cinematicUnavailableReason`) to learn whether it took.
    func setCinematicEnabled(_ enabled: Bool) throws {
        guard videoDeviceInput != nil else { throw CameraSessionError.noDeviceAvailable }
        guard !enabled || isCinematicSupported else {
            throw CameraSessionError.configurationFailed("Cinematic capture not supported on this camera")
        }
        wantsCinematic = enabled
        // A reason left over from an earlier attempt would read as this attempt's answer.
        cinematicUnavailableReason = nil
        let currentFacing = facing
        sessionQueue.async { [weak self] in
            guard let self, let input = self.videoDeviceInput else { return }
            // Cinematic has its own camera (Dual Wide / TrueDepth), so switching it on or off is a
            // camera swap, not a flag flip — rebuild the session around the right device. When
            // that device is already the one in use, the lighter in-place path is enough.
            let position: AVCaptureDevice.Position = currentFacing == .back ? .back : .front
            let wantedDevice = enabled
                ? CinematicVideoSupport.cinematicDevice(for: position)
                : Self.device(for: currentFacing)
            if let wantedDevice, wantedDevice.uniqueID != input.device.uniqueID {
                do {
                    try self.configureSessionSync(facing: currentFacing)
                } catch {
                    self.failCinematic(error.localizedDescription)
                }
            } else {
                self.captureSession.beginConfiguration()
                self.applyCinematicSync(enabled, device: input.device, input: input)
                self.captureSession.commitConfiguration()
                self.applyZoomSync(device: input.device)
            }
            // A format swap rebuilds connections; rotation and mirroring have to be pushed back on.
            self.applyMirroring(facing: currentFacing)
            self.applyRotationAngles(preview: self.lastPreviewAngle, capture: self.lastCaptureAngle)
            if !enabled {
                // Back to whatever resolution the user actually picked.
                self.applyResolution(self.lastResolution, fps: self.lastFPS)
            }
        }
    }

    /// The system's simulated aperture (f-number) for Cinematic capture — lower is shallower.
    /// Remembered even when Cinematic isn't running, so the value the user picked is re-applied
    /// the next time the effect engages (after a camera flip or a resolution change) instead of
    /// silently reverting to the system default.
    func setCinematicAperture(_ fNumber: Float) {
        requestedAperture = Double(fNumber)
        sessionQueue.async { [weak self] in
            guard let self, let input = self.videoDeviceInput, self.isCinematicActive else { return }
            self.captureSession.beginConfiguration()
            CinematicVideoSupport.setSimulatedAperture(fNumber, on: input)
            self.captureSession.commitConfiguration()
        }
    }

    /// The f-stop range the active Cinematic format actually renders across, for the UI slider.
    /// `nil` when Cinematic isn't running or the OS doesn't publish a range.
    var cinematicApertureRange: (min: Float, max: Float, default: Float)? {
        guard let device = videoDeviceInput?.device else { return nil }
        return CinematicVideoSupport.apertureRange(for: device.activeFormat)
    }

    private static func device(for facing: CameraFacing) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = facing == .back ? .back : .front
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }
}
