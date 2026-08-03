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
    /// Destination for live cinematic composite frames — see `CinematicPreviewSink`.
    let cinematicPreview = CinematicPreviewSink()

    var runMode: StudioRunMode = .record
    var cinematicMode: CinematicMode = .off
    var resolution: CaptureResolution = .hd1080
    var fps: Double = 30

    var overlayOpacity: Double = 0.92
    var overlayHeightFraction: Double = 0.55

    /// On by default — framing help you have to go turn on every session isn't framing help.
    /// Toggled from Studio Settings.
    var showGrid = true
    var focusPoint: CGPoint?
    var isPermissionDenied = false
    var errorMessage: String?

    private var syncCoordinator: SyncCoordinator?
    private var modelContext: ModelContext?
    private var playbackReportTimer: Timer?
    /// The pending "countdown finished → start recording" task. Held so tapping the record button
    /// again during the countdown cancels the take instead of arming a second one.
    private var armedRecordTask: Task<Void, Never>?

    /// Whether a Companion device is connected and being fed frames.
    private var isCompanionStreaming = false

    /// True between tapping record and the countdown actually starting capture — the record button
    /// needs to read as "armed" immediately, not stay idle-looking for three seconds.
    var isArmed = false

    /// Stored, not computed. As a computed property this rebuilt a `PrompterDocument` — and, more
    /// importantly, *read the SwiftData `Script` model* — on every single access, including every
    /// SwiftUI body evaluation of the Studio screen and five times a second from the sync timer.
    /// Each of those reads re-registered an observation on the model, so ordinary SwiftData
    /// bookkeeping could invalidate the entire camera screen. It's snapshotted at load instead.
    private(set) var document: PrompterDocument

    /// Re-snapshots the document from the script (call after editing style/text).
    func refreshDocument() {
        document = PrompterDocument(markdown: script.bodyMarkdown, style: script.style ?? ScriptStyle())
        syncCoordinator?.publishDocument(document, title: script.title)
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
        document = PrompterDocument(markdown: script.bodyMarkdown, style: script.style ?? ScriptStyle())
    }

    func attach(syncCoordinator: SyncCoordinator, modelContext: ModelContext) {
        self.syncCoordinator = syncCoordinator
        self.modelContext = modelContext
        syncCoordinator.onRemoteCommand = { [weak self] command in
            self?.handleRemoteCommand(command)
        }
        syncCoordinator.onConnectedPeersChanged = { [weak self] hasPeers in
            self?.setCompanionStreaming(hasPeers)
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
        recordingCoordinator.synthetic.onPreviewFrame = { [weak self] sampleBuffer in
            Task { @MainActor in self?.cinematicPreview.submit(sampleBuffer) }
        }
        session.onRotationAnglesChanged = { [weak self] preview, capture in
            Task { @MainActor in
                self?.recordingCoordinator.synthetic.setPreviewRotation(delta: Double(preview - capture))
            }
        }
    }

    /// Companion mirroring is expensive (downscale + JPEG-encode every frame) and was running
    /// permanently, whether or not a second device was ever connected. It's now bound to actually
    /// having a peer — as is the whole raw-frame capture path it depends on.
    private func setCompanionStreaming(_ enabled: Bool) {
        isCompanionStreaming = enabled
        previewStreamer.setEnabled(enabled)
        syncFrameTapRequirement()
        if enabled {
            startPlaybackReporting()
            syncCoordinator?.publishDocument(document, title: script.title)
        } else {
            playbackReportTimer?.invalidate()
            playbackReportTimer = nil
        }
    }

    /// The raw-frame outputs stay detached from the capture session unless something is actually
    /// consuming frames — cinematic compositing or a connected Companion.
    private func syncFrameTapRequirement() {
        let needsFrames = isCompanionStreaming || cinematicMode == .cinematic
        session.setDataOutputsEnabled(needsFrames)
    }

    func start() async {
        // The prompter script must always load, independent of anything camera-related — it's
        // a text overlay, not a byproduct of camera setup. Previously this was nested inside the
        // camera permission guard and the `session.configure()` `do`/`catch`, so any camera-side
        // failure (permission not granted, no matching format, anything) silently left the
        // prompter blank forever, with no visible error. That's the actual bug behind "the
        // prompter text isn't shown" reports.
        prompterController.onDidFinish = { [weak self] in
            self?.stopRecordingIfNeeded()
        }
        recordingCoordinator.onRecordingFailed = { [weak self] message in
            self?.errorMessage = message
        }
        prompterController.loadDocument(document)
        // Sync reporting only runs while a Companion is actually connected — see
        // `setCompanionStreaming`. It used to tick five times a second unconditionally, rebuilding
        // the whole document each tick for nobody.

        let status = await CameraAuthorization.requestAll()
        guard status.camera == .authorized, status.microphone == .authorized else {
            isPermissionDenied = true
            return
        }
        do {
            try await session.configure()
            // Resolution is applied *after* the session is running, and failures are non-fatal:
            // a device with no exact 1080p/4K format at the requested fps simply keeps the
            // session preset it already negotiated rather than losing its capture connections.
            session.start()
            session.applyResolution(resolution, fps: fps)
            levelMonitor.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        cancelArmedRecording()
        session.stop()
        levelMonitor.stop()
        playbackReportTimer?.invalidate()
        playbackReportTimer = nil
        previewStreamer.setEnabled(false)
        recordingCoordinator.synthetic.setPreviewEnabled(false)
        cinematicPreview.clear()
        session.setDataOutputsEnabled(false)
        stopRecordingIfNeeded()
    }

    // MARK: User actions

    /// Re-applies the chosen resolution/frame rate to the live session. Called when the Studio
    /// Settings pickers change — before, changing them updated the picker and nothing else until
    /// the next time Studio was opened.
    func applyCaptureSettings() {
        session.applyResolution(resolution, fps: fps)
    }

    func toggleFacing() {
        Task {
            try? await session.toggleFacing()
        }
    }

    func setAudioDevice(_ device: AVCaptureDevice?) {
        Task {
            try? await session.setAudioDevice(device)
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
        // Frames are only tapped while the effect is on, and the live composite preview is what
        // makes the toggle mean something on screen instead of only inside the recorded file.
        syncFrameTapRequirement()
        let wantsSyntheticPreview = resolvedCinematicKind == .synthetic
        recordingCoordinator.synthetic.setPreviewEnabled(wantsSyntheticPreview)
        if !wantsSyntheticPreview { cinematicPreview.clear() }
    }

    /// Tapping record while a countdown is already running cancels it — otherwise the only way out
    /// was to wait for a take you no longer wanted to start.
    func toggleRecording() {
        if isArmed {
            cancelArmedRecording()
        } else if recordingCoordinator.isRecording {
            stopRecordingIfNeeded()
        } else {
            startCountdownAndRecord()
        }
    }

    func startCountdownAndRecord() {
        errorMessage = nil
        guard runMode == .record else {
            prompterController.startCountdown(seconds: 3)
            return
        }
        prompterController.startCountdown(seconds: 3)
        isArmed = true
        armedRecordTask?.cancel()
        armedRecordTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isArmed = false
            self.beginRecording()
        }
    }

    func cancelArmedRecording() {
        armedRecordTask?.cancel()
        armedRecordTask = nil
        isArmed = false
        prompterController.cancelCountdown()
    }

    func beginRecording() {
        guard runMode == .record else { return }
        guard let modelContext else {
            errorMessage = "Studio isn't ready yet — reopen this script and try again."
            return
        }
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

    /// Streams playback position to a connected Companion. Only the *position* — the document
    /// itself is published once when the peer connects (and again on `refreshDocument`), instead
    /// of being re-encoded and re-sent five times a second forever.
    private func startPlaybackReporting() {
        playbackReportTimer?.invalidate()
        playbackReportTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
