import AVFoundation
import Observation
import SwiftData
import UIKit

enum StudioRunMode: String, CaseIterable {
    case record = "Record"
    case promptOnly = "Prompt Only"
}

/// Composition root for the camera + teleprompter "Studio" screen: owns the camera session,
/// recorder, cinematic controllers, prompter controller, and the Director side of SyncKit, and
/// wires them together. Individual subsystems stay independently testable behind their own
/// protocols/types; this view model just coordinates.
@MainActor
@Observable
final class CameraStudioViewModel {
    let script: Script
    let session = AVCameraSession()
    let recordingCoordinator = RecordingCoordinator()
    // `var`, not `let`: StudioSettingsSheet derives a nested Binding via `$viewModel.realCinematic.focusMode`,
    // which requires a WritableKeyPath (i.e. a settable property), even though the object itself is never reassigned.
    var realCinematic = RealCinematicController()
    let levelMonitor = LevelMonitor()
    let prompterController = PrompterController()
    private let previewStreamer = AdaptivePreviewStreamer()
    private let videoMultiplexer = VideoFrameMultiplexer()

    var runMode: StudioRunMode = .record
    var cinematicMode: CinematicMode = .off
    var resolution: CaptureResolution = .hd1080
    var fps: Double = 30

    var overlayOpacity: Double = 0.92
    var overlayHeightFraction: Double = 0.55
    var overlayVerticalOffset: Double = -0.08 // negative = shifted toward lens/top

    var showGrid = false
    var focusPoint: CGPoint?
    var isPermissionDenied = false
    var errorMessage: String?

    private var syncCoordinator: SyncCoordinator?
    private var modelContext: ModelContext?
    private var playbackReportTimer: Timer?

    var document: PrompterDocument {
        PrompterDocument(markdown: script.bodyMarkdown, style: script.style ?? ScriptStyle())
    }

    var resolvedCinematicKind: CinematicKind {
        guard cinematicMode == .cinematic else { return .none }
        return RealCinematicController.isSupported(session: session) ? .real : .synthetic
    }

    init(script: Script) {
        self.script = script
        if script.style == nil {
            script.style = ScriptStyle()
        }
    }

    func attach(syncCoordinator: SyncCoordinator, modelContext: ModelContext) {
        self.syncCoordinator = syncCoordinator
        self.modelContext = modelContext
        syncCoordinator.onRemoteCommand = { [weak self] command in
            self?.handleRemoteCommand(command)
        }
        videoMultiplexer.add(previewStreamer)
        videoMultiplexer.add(recordingCoordinator.synthetic)
        session.videoDataDelegate = videoMultiplexer
        session.audioDataDelegate = recordingCoordinator.synthetic
        previewStreamer.onFrameEncoded = { [weak self] jpeg in
            Task { @MainActor in self?.syncCoordinator?.publishPreviewFrame(jpeg) }
        }
        previewStreamer.onAvailabilityChanged = { [weak self] available in
            Task { @MainActor in self?.syncCoordinator?.publishPreviewAvailability(available) }
        }
    }

    func start() async {
        let status = await CameraAuthorization.requestAll()
        guard status.camera == .authorized, status.microphone == .authorized else {
            isPermissionDenied = true
            return
        }
        do {
            try await session.configure()
            try? session.setResolution(resolution, fps: fps)
            session.start()
            levelMonitor.start()
            prompterController.loadDocument(document)
            prompterController.onDidFinish = { [weak self] in
                self?.stopRecordingIfNeeded()
            }
            startPlaybackReporting()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        session.stop()
        levelMonitor.stop()
        playbackReportTimer?.invalidate()
        stopRecordingIfNeeded()
    }

    // MARK: User actions

    func toggleFacing() {
        Task {
            try? await session.toggleFacing()
        }
    }

    func focus(at point: CGPoint) {
        session.focus(at: point)
        focusPoint = point
    }

    func setZoom(_ factor: CGFloat) {
        session.setZoom(factor)
    }

    func toggleCinematic() {
        cinematicMode = cinematicMode == .off ? .cinematic : .off
        if resolvedCinematicKind == .real {
            try? realCinematic.enable(on: session)
        } else {
            realCinematic.disable(on: session)
        }
    }

    func startCountdownAndRecord() {
        guard runMode == .record else {
            prompterController.startCountdown(seconds: 3)
            return
        }
        prompterController.startCountdown(seconds: 3)
        Task {
            try? await Task.sleep(for: .seconds(3))
            beginRecording()
        }
    }

    func beginRecording() {
        guard runMode == .record, let modelContext else { return }
        do {
            try recordingCoordinator.start(
                session: session,
                cinematicKind: resolvedCinematicKind,
                resolution: resolution,
                saveToPhotos: true
            )
            syncCoordinator?.publishRecordingState(isRecording: true, elapsed: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
        _ = modelContext
    }

    func stopRecordingIfNeeded() {
        guard recordingCoordinator.isRecording, let modelContext else { return }
        Task {
            await recordingCoordinator.stop(
                script: script,
                cinematicKind: resolvedCinematicKind,
                cameraFacing: session.facing,
                resolution: resolution,
                saveToPhotos: true,
                modelContext: modelContext
            )
            syncCoordinator?.publishRecordingState(isRecording: false, elapsed: 0)
        }
    }

    private func handleRemoteCommand(_ command: SyncMessage.RemoteCommand) {
        switch command {
        case .togglePlayback: prompterController.toggle()
        case .jumpToTop: prompterController.jumpToTop()
        case .jumpToFraction(let fraction): prompterController.jumpToFraction(fraction)
        case .setSpeed(let speed): prompterController.setSpeed(speed)
        case .setFontSize(let size): prompterController.setFontSize(size)
        case .startRecording: beginRecording()
        case .stopRecording: stopRecordingIfNeeded()
        case .startCountdown(let seconds): prompterController.startCountdown(seconds: seconds)
        }
    }

    private func startPlaybackReporting() {
        playbackReportTimer?.invalidate()
        playbackReportTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.syncCoordinator?.publishDocument(self.document, title: self.script.title)
                self.syncCoordinator?.publishPlayback(
                    fraction: self.prompterController.progress,
                    isPlaying: self.prompterController.isPlaying,
                    speedPxPerSec: self.prompterController.speedPxPerSec,
                    fontSize: self.prompterController.fontSize
                )
            }
        }
    }
}
