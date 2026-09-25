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
    /// Live Cinematic subject metadata, shared between the preview overlay (which draws the
    /// system's detected subjects) and `realCinematic` (which matches a tap to one of them).
    let cinematicSubjectRelay = CinematicSubjectRelay()
    private let cinematicSubjectObserver = CinematicSubjectObserver()

    var runMode: StudioRunMode = .record
    var cinematicMode: CinematicMode = .off
    /// 4K/30 by default: this is a camera app whose whole job is the take you keep, and every
    /// iPhone it can run on shoots 4K. Devices (or modes) that can't are walked down to the
    /// nearest real format by `AVCameraSession.applyResolution`, which says so rather than
    /// quietly recording something else.
    var resolution: CaptureResolution = .uhd4k
    var fps: Double = 30

    /// What the camera actually settled on when it couldn't do what was asked. Mirrored from the
    /// session so views can read it without observing the camera object directly.
    var captureFallbackNote: String? { session.captureFallbackNote }

    var overlayOpacity: Double = 0.92
    var overlayHeightFraction: Double = 0.55

    /// On by default — framing help you have to go turn on every session isn't framing help.
    /// Toggled from Studio Settings.
    var showGrid = true

    /// Pinch-to-zoom and the on-screen lens button. **Off by default**: the camera sits at 1×,
    /// the framing most takes want, and a stray pinch mid-take can't knock it off. Remembered
    /// between sessions; toggled from Studio Settings.
    var isZoomControlEnabled: Bool = UserDefaults.standard.bool(forKey: CameraStudioViewModel.zoomControlKey) {
        didSet {
            UserDefaults.standard.set(isZoomControlEnabled, forKey: Self.zoomControlKey)
            // Turning it off puts the camera back to 1×, so "off" always means the default framing.
            if !isZoomControlEnabled { session.setZoom(1) }
        }
    }
    private static let zoomControlKey = "studio.zoomControlEnabled"
    /// Zoom at the start of the current pinch; the gesture's scale is relative to it.
    @ObservationIgnored private var pinchStartZoom: CGFloat = 1
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

    /// Whether Apple's Cinematic is actually running. Stored rather than computed: it settles a
    /// moment after the toggle, once the capture session has accepted (or declined) it.
    private(set) var resolvedCinematicKind: CinematicKind = .none
    private var cinematicSettleTask: Task<Void, Never>?

    /// True while the real hardware path is in use, for the on-screen badge.
    var isUsingAppleCinematic: Bool { resolvedCinematicKind == .real }

    /// Simulated aperture (f-number) for Apple's Cinematic capture. f/2.8 is roughly what the
    /// stock Camera app opens at.
    private(set) var cinematicAperture: Double = 2.8

    /// The f-stop range the hardware will honour for the active Cinematic format, falling back to
    /// a sane span when the system doesn't publish one.
    var cinematicApertureRange: ClosedRange<Double> {
        guard let range = session.cinematicApertureRange else { return 2...16 }
        return Double(range.min)...Double(range.max)
    }

    /// Changes the script's typeface and re-publishes the document, so Studio, the editor preview
    /// and any linked Companion all switch at once. Written through the view model rather than
    /// bound straight to the model because `document` is a snapshot — see `refreshDocument`.
    func setTypeface(_ typeface: PrompterTypeface) {
        script.style?.fontName = typeface.rawValue
        refreshDocument()
        prompterController.loadDocument(document)
    }

    func setCinematicAperture(_ fNumber: Double) {
        cinematicAperture = fNumber
        session.setCinematicAperture(Float(fNumber))
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
        session.videoDataDelegate = videoMultiplexer
        // Subject detection for Apple's Cinematic path. The output it feeds is only attached to
        // the session while hardware Cinematic is actually running, so this costs nothing the rest
        // of the time.
        cinematicSubjectObserver.relay = cinematicSubjectRelay
        session.cinematicMetadataDelegate = cinematicSubjectObserver
        cinematicSubjectRelay.onSubjects = { [weak self] subjects in
            self?.realCinematic.updateDetectedSubjects(subjects)
        }
        previewStreamer.onFrameEncoded = { [weak self] jpeg in
            Task { @MainActor in self?.syncCoordinator?.publishPreviewFrame(jpeg) }
        }
        previewStreamer.onAvailabilityChanged = { [weak self] available in
            Task { @MainActor in self?.syncCoordinator?.publishPreviewAvailability(available) }
        }

        // Studio *is* the Director screen, so say so — but only for someone actually using sync,
        // so opening a script on a device that's set up as a Companion doesn't quietly reassign it.
        if syncCoordinator.isHosting || syncCoordinator.hasConnectedPeers {
            syncCoordinator.setRole(.director)
        }

        // `onConnectedPeersChanged` is edge-triggered, and the natural order of operations is to
        // pair the two devices *first* (Settings → Connect a Device) and then go live. In that
        // order the edge had already passed before Studio existed: no document was ever published,
        // no playback was reported, and no camera frames were streamed — the Companion sat on
        // "Waiting for Director…" for the whole take. Catch up on the state instead of waiting for
        // an edge that already happened.
        if syncCoordinator.hasConnectedPeers {
            setCompanionStreaming(true)
        }
    }

    /// Drops this view model's claim on the shared sync coordinator. Without it, a Studio screen
    /// the user has already left stays wired up as the remote-command target, so a Companion's
    /// record button would drive a stopped session.
    private func detachSync() {
        guard let syncCoordinator else { return }
        syncCoordinator.onRemoteCommand = nil
        syncCoordinator.onConnectedPeersChanged = nil
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

    /// The raw-frame output stays detached from the capture session unless a connected Companion
    /// is actually consuming frames. Apple's Cinematic renders inside the capture pipeline, so it
    /// never needs one.
    private func syncFrameTapRequirement() {
        session.setDataOutputsEnabled(isCompanionStreaming)
    }

    func start() async {
        // The prompter script must always load, independent of anything camera-related — it's
        // a text overlay, not a byproduct of camera setup. Previously this was nested inside the
        // camera permission guard and the `session.configure()` `do`/`catch`, so any camera-side
        // failure (permission not granted, no matching format, anything) silently left the
        // prompter blank forever, with no visible error. That's the actual bug behind "the
        // prompter text isn't shown" reports.
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
            // `levelMonitor` is deliberately NOT started: nothing on screen displays the bubble
            // level, and starting it meant CoreMotion waking the **main thread** 30 times a second
            // to publish an observable value no view reads. Start it here again the day a level
            // indicator is actually shown.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        detachSync()
        cancelArmedRecording()
        cinematicSettleTask?.cancel()
        cinematicSettleTask = nil
        session.stop()
        levelMonitor.stop()
        playbackReportTimer?.invalidate()
        playbackReportTimer = nil
        previewStreamer.setEnabled(false)
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

    /// A tap on the preview. While Apple's Cinematic path is running this is a **rack focus**, not
    /// an autofocus: the system takes the point, finds the subject there, starts tracking it and
    /// pulls focus onto it with the chosen focus style — which is the whole reason to shoot
    /// Cinematic in the first place. Everywhere else it stays ordinary tap-to-focus/expose.
    func focus(at point: CGPoint) {
        if resolvedCinematicKind == .real, realCinematic.rackFocus(at: point, on: session) {
            focusPoint = point
            return
        }
        session.focus(at: point)
        focusPoint = point
    }

    func setZoom(_ factor: CGFloat) {
        guard isZoomControlEnabled else { return }
        session.setZoom(factor)
    }

    /// Pinch on the preview. The scale is relative to where the pinch started — multiplying the
    /// *live* zoom by it on every update compounded, so the image lurched instead of tracking the
    /// fingers.
    func handlePinch(began: Bool, scale: CGFloat) {
        guard isZoomControlEnabled else { return }
        if began { pinchStartZoom = session.currentZoom }
        session.setZoom(pinchStartZoom * scale)
    }

    /// One tap on the lens button: the next lens stop up, wrapping round to the widest.
    func cycleZoomPreset() {
        guard isZoomControlEnabled else { return }
        let presets = session.zoomPresets
        let current = session.currentZoom
        let next = presets.first { $0 > current + 0.05 } ?? presets.first ?? 1
        session.setZoom(next)
    }

    /// Cinematic is **Apple's** Cinematic mode only — the one the stock Camera app shoots, with
    /// the system's depth rendering and rack focus baked into the file. There is no simulated
    /// stand-in: when the phone or iOS version can't do it, the button stays off and says why.
    func toggleCinematic() {
        cinematicMode = cinematicMode == .off ? .cinematic : .off
        cinematicSettleTask?.cancel()
        cinematicSettleTask = nil

        guard cinematicMode == .cinematic else {
            realCinematic.disable(on: session)
            settleCinematicKind()
            return
        }

        guard session.isCinematicSupported, (try? realCinematic.enable(on: session)) != nil else {
            errorMessage = CinematicVideoSupport.isAvailableOnThisOS
                ? "This iPhone can't shoot Apple Cinematic with this camera."
                : "Apple Cinematic needs iOS 26 or later."
            cinematicMode = .off
            applyCinematicKind(.none)
            return
        }

        // Assume it took while the session swaps cameras, then confirm. The swap to the Dual
        // Wide / TrueDepth camera takes longer than a flag flip, so give it a moment.
        applyCinematicKind(.real)
        cinematicSettleTask = Task { [weak self] in
            // Wait for the session to answer — accepted or declined with a reason — rather than
            // guessing a fixed delay: a camera swap takes longer on some phones than others.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                if self.session.isCinematicActive || self.session.cinematicUnavailableReason != nil { break }
            }
            guard !Task.isCancelled else { return }
            self?.settleCinematicKind()
        }
    }

    private func settleCinematicKind() {
        guard cinematicMode == .cinematic else {
            applyCinematicKind(.none)
            return
        }
        guard session.isCinematicActive else {
            // Say *why* it didn't take, and switch the button back off — no pretend version.
            errorMessage = session.cinematicUnavailableReason ?? "iOS didn't switch Cinematic on."
            cinematicMode = .off
            realCinematic.disable(on: session)
            applyCinematicKind(.none)
            return
        }
        applyCinematicKind(.real)
    }

    private func applyCinematicKind(_ kind: CinematicKind) {
        guard kind != resolvedCinematicKind else { return }
        resolvedCinematicKind = kind
        if kind == .real { session.setCinematicAperture(Float(cinematicAperture)) }
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
