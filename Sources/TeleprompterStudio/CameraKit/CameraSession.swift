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

    /// Frames delegate for the synthetic cinematic pipeline / live preview streaming to hook into.
    weak var videoDataDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    weak var audioDataDelegate: AVCaptureAudioDataOutputSampleBufferDelegate?

    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    let movieFileOutput = AVCaptureMovieFileOutput()
    let videoDataOutput = AVCaptureVideoDataOutput()
    let audioDataOutput = AVCaptureAudioDataOutput()
    private let dataOutputQueue = DispatchQueue(label: "studio.camera.dataOutput")

    var isCinematicSupported: Bool {
        guard let device = videoDeviceInput?.device else { return false }
        if #available(iOS 26.0, *) {
            return device.activeFormat.isCinematicVideoCaptureSupported
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

        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if captureSession.canAddInput(audioInput) {
                captureSession.addInput(audioInput)
                audioDeviceInput = audioInput
            }
        }

        if captureSession.canAddOutput(movieFileOutput) {
            captureSession.addOutput(movieFileOutput)
        }

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

        if let connection = videoDataOutput.connection(with: .video) {
            connection.videoRotationAngle = 90 // portrait
            if facing == .front, connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        DispatchQueue.main.async {
            self.facing = facing
            self.minZoom = videoDevice.minAvailableVideoZoomFactor
            self.maxZoom = min(videoDevice.maxAvailableVideoZoomFactor, 8)
        }
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

    func setCinematicEnabled(_ enabled: Bool) throws {
        guard let device = videoDeviceInput?.device else { throw CameraSessionError.noDeviceAvailable }
        if #available(iOS 26.0, *) {
            guard device.activeFormat.isCinematicVideoCaptureSupported else {
                throw CameraSessionError.configurationFailed("Cinematic capture not supported on active format")
            }
            try device.lockForConfiguration()
            videoDeviceInput?.isCinematicVideoCaptureEnabled = enabled
            device.unlockForConfiguration()
        }
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
