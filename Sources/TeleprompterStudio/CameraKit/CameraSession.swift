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
    private(set) var currentZoom: CGFloat = 1.0
    private(set) var minZoom: CGFloat = 1.0
    private(set) var maxZoom: CGFloat = 4.0
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

    /// Frames delegate for the synthetic cinematic pipeline / live preview streaming to hook into.
    weak var videoDataDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    weak var audioDataDelegate: AVCaptureAudioDataOutputSampleBufferDelegate?

    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    let movieFileOutput = AVCaptureMovieFileOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()
    let audioDataOutput = AVCaptureAudioDataOutput()
    private let dataOutputQueue = DispatchQueue(label: "studio.camera.dataOutput")

    /// Whether the raw-frame taps (`videoDataOutput`/`audioDataOutput`) are attached to the
    /// session. **Off by default.** These outputs are only needed by the two features that consume
    /// individual frames — the synthetic cinematic pipeline and the Companion preview stream — but
    /// they used to be attached unconditionally, so every ordinary session paid for a second
    /// full-rate video path (and a per-frame delegate hop) that nothing was reading. On a 1080p60
    /// session that is a large, permanent tax on memory bandwidth and thermals, which is exactly
    /// what "the whole app feels laggy / buttons need several taps" looks like from the outside:
    /// the main thread competing with a capture pipeline that is doing pointless work.
    private var dataOutputsEnabled = false

    /// Real hardware Cinematic capture support. See BUILD_NOTES.md "Cinematic API surface":
    /// `AVCaptureDevice.Format.isCinematicVideoCaptureSupported` does not exist in the SDK this
    /// project has actually been compiled against (confirmed by a real build, not guessed), so
    /// this always resolves to `false` for now, and `RealCinematicController` — and therefore
    /// `CameraStudioViewModel.resolvedCinematicKind` — cleanly falls back to the fully-working
    /// `SyntheticCinematicPipeline` path. Once you have the real iOS 26 SDK, replace the `false`
    /// below with the real capability check (probably still `device.activeFormat.<something>`,
    /// just under a different, real member name) and this whole app gains real Cinematic
    /// support with no other changes needed anywhere else.
    var isCinematicSupported: Bool {
        guard videoDeviceInput?.device != nil else { return false }
        if #available(iOS 26.0, *) {
            return false // see doc comment above
        }
        return false
    }

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

        guard let videoDevice = Self.device(for: facing) else {
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

        DispatchQueue.main.async {
            self.facing = facing
            self.minZoom = videoDevice.minAvailableVideoZoomFactor
            self.maxZoom = min(videoDevice.maxAvailableVideoZoomFactor, 8)
        }
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
                self.captureSession.removeOutput(self.audioDataOutput)
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

        audioDataOutput.setSampleBufferDelegate(audioDataDelegate, queue: dataOutputQueue)
        if captureSession.canAddOutput(audioDataOutput) {
            captureSession.addOutput(audioDataOutput)
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
            guard let self, let device = self.videoDeviceInput?.device else { return }
            guard let format = Self.bestFormat(for: device, resolution: resolution, fps: fps) else { return }
            self.captureSession.beginConfiguration()
            defer { self.captureSession.commitConfiguration() }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                return
            }
            // Format changes rebuild connections, so rotation and mirroring have to be re-applied.
            self.applyMirroring(facing: self.facing)
            self.applyRotationAngles(preview: self.lastPreviewAngle, capture: self.lastCaptureAngle)
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

    func setZoom(_ factor: CGFloat) {
        guard let device = videoDeviceInput?.device else { return }
        let clamped = max(minZoom, min(factor, maxZoom))
        try? device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        currentZoom = clamped
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

    /// See the doc comment on `isCinematicSupported` and BUILD_NOTES.md "Cinematic API
    /// surface" — `isCinematicSupported` currently always returns `false`, so
    /// `RealCinematicController.enable(on:)` never calls this with `enabled: true` in practice;
    /// it's left real/callable (rather than deleted) so wiring in the actual iOS 26 SDK members
    /// later is a two-line change, not a redesign.
    func setCinematicEnabled(_ enabled: Bool) throws {
        guard videoDeviceInput?.device != nil else { throw CameraSessionError.noDeviceAvailable }
        guard isCinematicSupported else {
            throw CameraSessionError.configurationFailed("Cinematic capture not supported on active format")
        }
        // try device.lockForConfiguration()
        // videoDeviceInput?.isCinematicVideoCaptureEnabled = enabled
        // device.unlockForConfiguration()
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
