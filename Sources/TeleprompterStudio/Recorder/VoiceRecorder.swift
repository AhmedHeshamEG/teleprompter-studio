import AVFoundation
import Observation
import SwiftData

/// The voice side of the app: a lossless audio recorder for reading a script without a camera.
///
/// Everything here is stock AVFoundation — `AVAudioSession` for the route and the mic, and
/// **Apple Lossless (ALAC), 24-bit** into an `.m4a`. Lossless means what the mic heard is what's in
/// the file: no AAC smearing on sibilants, nothing baked in that an edit can't undo. Takes are
/// written straight into Documents/Recordings — not a temp file moved at the end — so a crash or a
/// call mid-take still leaves everything up to that point on disk, and that folder is visible in
/// the Files app.
///
/// A take can be paused and resumed into the same file, like Voice Memos, and thrown away without
/// ever reaching the takes list.
///
/// Two ways to capture, picked per take:
/// - **Standard** (the default): `AVAudioRecorder`, 48 kHz, nothing between the mic and the file.
/// - **Voice Isolation** (opt-in, in the options menu): `AVAudioEngine` with Apple's voice
///   processing switched on. That is the only door iOS opens to its microphone modes — Voice
///   Isolation, Wide Spectrum — and the mode itself is chosen in Apple's own Mic Mode panel, not
///   imitated here. It also brings the call-style processing that comes with it (echo cancelling,
///   level control), which is why it's off unless asked for.
@MainActor
@Observable
final class VoiceRecorder: NSObject {
    enum TakeState: Equatable {
        case idle, recording, paused
    }

    private(set) var state: TakeState = .idle
    /// A take is in progress — recording or paused.
    var isRecording: Bool { state != .idle }
    var isPaused: Bool { state == .paused }
    /// The system paused the take (a phone call, Siri, an alarm). It resumes on its own when the
    /// interruption ends, if iOS says it may.
    private(set) var isInterrupted = false
    private(set) var elapsed: TimeInterval = 0
    /// Input level, 0…1, for the meter.
    private(set) var level: Float = 0
    /// Recent levels, oldest first, for the live waveform. One entry per meter tick while the
    /// take is actually recording; a pause adds nothing, so the waveform stops where the voice did.
    private(set) var levelHistory: [Float] = []
    private(set) var inputName = ""
    private(set) var inputs: [AVAudioSessionPortDescription] = []
    var errorMessage: String?
    var isPermissionDenied = false

    /// Opt-in; see the type's doc comment. Can't change mid-take.
    var voiceIsolationEnabled: Bool = UserDefaults.standard.bool(forKey: "voice.isolation") {
        didSet { UserDefaults.standard.set(voiceIsolationEnabled, forKey: "voice.isolation") }
    }
    /// The microphone mode iOS is actually applying ("Standard", "Voice Isolation", …), read back
    /// from the system while a processed take runs. `nil` when it doesn't apply.
    private(set) var activeMicModeName: String?

    /// Whether the take (voice processing) that's running uses the Voice Isolation path.
    private(set) var takeUsesVoiceProcessing = false

    static let maxHistory = 600
    static let meterInterval: TimeInterval = 0.05

    private var backend: VoiceTakeBackend?
    private var meterTimer: Timer?
    private var currentTakeURL: URL?
    private var observers: [NSObjectProtocol] = []

    // MARK: Session

    /// Asks for the mic and sets the audio session up for recording. Returns false (with
    /// `isPermissionDenied` or `errorMessage` set) when it can't.
    func prepare() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else {
            isPermissionDenied = true
            return false
        }
        do {
            try configureSession(voiceProcessing: false)
        } catch {
            errorMessage = "Couldn't open the microphone: \(error.localizedDescription)"
            return false
        }
        observeSession()
        refreshInputs()
        startMetering()
        return true
    }

    private func configureSession(voiceProcessing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // `.playAndRecord` so a finished take can be played back without switching sessions;
        // `.defaultToSpeaker` so that playback comes out of the speaker, not the earpiece.
        // Deliberately **no** `.allowBluetooth`: that is the hands-free profile, which drags
        // the whole route down to 16 kHz phone-call audio. AirPods stay the *output*; the
        // phone's own mic (or a wired/USB one) does the recording — unless iOS 26 can record
        // AirPods at full quality, which is what the option below asks for.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if #available(iOS 26.0, *) {
            options.insert(.bluetoothHighQualityRecording)
        }
        try session.setCategory(.playAndRecord, mode: voiceProcessing ? .voiceChat : .default, options: options)
        try? session.setPreferredSampleRate(48_000)
        try session.setActive(true)
    }

    func teardown() {
        if isRecording { _ = stop() }
        stopMetering()
        backend = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Mics iOS can record from right now: the built-in one, plus any wired, USB or Lightning mic.
    func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        inputs = session.availableInputs ?? []
        inputName = session.currentRoute.inputs.first?.portName ?? "iPhone Microphone"
    }

    func selectInput(_ port: AVAudioSessionPortDescription) {
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(port)
        } catch {
            errorMessage = "Couldn't switch to \(port.portName)."
        }
        refreshInputs()
    }

    /// Apple's Mic Mode panel (Standard / Voice Isolation / Wide Spectrum) — the same one Control
    /// Center shows. The choice is the system's and it remembers it for this app.
    func showSystemMicModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInputs() }
        })
        // The engine stops itself when the route changes under it (a mic plugged in mid-take);
        // start it again so the take carries on.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                self.backend?.recover()
            }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // iOS has already stopped the input; the file so far is safe on disk.
            if state == .recording { isInterrupted = true }
        case .ended:
            guard isInterrupted else { return }
            isInterrupted = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume), state == .recording {
                try? AVAudioSession.sharedInstance().setActive(true)
                backend?.recover()
            } else {
                // Leave it paused rather than recording silence: the reader decides.
                backend?.pause()
                state = .paused
                errorMessage = "Recording paused by iOS. Tap resume to carry on."
            }
        @unknown default:
            break
        }
    }

    // MARK: Recording

    func start(scriptTitle: String) throws {
        guard state == .idle else { return }
        let url = try Self.newTakeURL(scriptTitle: scriptTitle)
        let useProcessing = voiceIsolationEnabled
        try? configureSession(voiceProcessing: useProcessing)
        let backend: VoiceTakeBackend
        do {
            if useProcessing {
                backend = try ProcessedTakeBackend(url: url)
            } else {
                backend = try FileTakeBackend(url: url, owner: self)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard backend.record() else {
            backend.stop()
            try? FileManager.default.removeItem(at: url)
            throw VoiceRecorderError.couldNotStart
        }
        self.backend = backend
        currentTakeURL = url
        takeUsesVoiceProcessing = useProcessing
        state = .recording
        isInterrupted = false
        elapsed = 0
        levelHistory = []
        refreshMicMode()
    }

    func pause() {
        guard state == .recording else { return }
        backend?.pause()
        elapsed = backend?.currentTime ?? elapsed
        state = .paused
    }

    func resume() {
        guard state == .paused, let backend else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        guard backend.record() else {
            errorMessage = VoiceRecorderError.couldNotStart.localizedDescription
            return
        }
        errorMessage = nil
        state = .recording
    }

    /// Ends the take and returns its file and length.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard state != .idle, let backend, let url = currentTakeURL else { return nil }
        let duration = backend.currentTime
        backend.stop()
        finishTake()
        return (url, duration)
    }

    /// Ends the take and deletes it, as if it never happened.
    func discard() {
        guard state != .idle, let backend else { return }
        backend.stop()
        if let url = currentTakeURL { try? FileManager.default.removeItem(at: url) }
        finishTake()
        elapsed = 0
        levelHistory = []
    }

    private func finishTake() {
        backend = nil
        currentTakeURL = nil
        state = .idle
        isInterrupted = false
        activeMicModeName = nil
        if takeUsesVoiceProcessing {
            // Back to the untouched path for playback and the next standard take.
            try? configureSession(voiceProcessing: false)
        }
        takeUsesVoiceProcessing = false
    }

    fileprivate func backendFailed(_ message: String) {
        errorMessage = message
        _ = stop()
    }

    private func refreshMicMode() {
        guard takeUsesVoiceProcessing else {
            activeMicModeName = nil
            return
        }
        activeMicModeName = AVCaptureDevice.activeMicrophoneMode.displayName
    }

    // MARK: Takes on disk

    /// Records the finished take in the library alongside the script's video takes.
    func saveTake(_ url: URL, duration: TimeInterval, script: Script, in context: ModelContext) -> Recording {
        let recording = Recording(
            script: script,
            relativePath: url.lastPathComponent,
            durationSec: duration,
            resolutionWidth: 0,
            resolutionHeight: 0
        )
        context.insert(recording)
        try? context.save()
        return recording
    }

    // MARK: Metering

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMeter() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private var meterTicks = 0

    private func tickMeter() {
        guard state == .recording, let backend else {
            if level != 0 { level = max(0, level - 0.08) }
            return
        }
        let current = backend.level()
        level = current
        elapsed = backend.currentTime
        levelHistory.append(current)
        if levelHistory.count > Self.maxHistory {
            levelHistory.removeFirst(levelHistory.count - Self.maxHistory)
        }
        meterTicks += 1
        if meterTicks % 20 == 0 { refreshMicMode() }
    }

    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func safeFileName(_ title: String) -> String {
        title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80)
            .description
    }

    private static func newTakeURL(scriptTitle: String) throws -> URL {
        let directory = recordingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeTitle = safeFileName(scriptTitle).prefix(60)
        let name = "\(safeTitle.isEmpty ? "Voice" : String(safeTitle)) \(formatter.string(from: Date())).m4a"
        return directory.appendingPathComponent(name)
    }
}

enum VoiceRecorderError: LocalizedError {
    case couldNotStart
    case noInput

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "The microphone didn't start. Check that no other app is using it, then try again."
        case .noInput: return "No microphone is available right now."
        }
    }
}

extension AVCaptureDevice.MicrophoneMode {
    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        @unknown default: return "Standard"
        }
    }
}

// MARK: - Backends

/// One way of getting a take onto disk. `record()` starts or resumes, `pause()` holds the file
/// open, `stop()` finalises it.
@MainActor
private protocol VoiceTakeBackend: AnyObject {
    func record() -> Bool
    func pause()
    func stop()
    /// Get going again after iOS stopped the input under us (an interruption, a route change).
    func recover()
    var currentTime: TimeInterval { get }
    /// 0…1, -50 dBFS and below reading as silence.
    func level() -> Float
}

private func normalizedLevel(decibels: Float) -> Float {
    max(0, min(1, (decibels + 50) / 50))
}

/// Standard takes: `AVAudioRecorder`, the mic straight to ALAC at 48 kHz.
@MainActor
private final class FileTakeBackend: NSObject, VoiceTakeBackend, AVAudioRecorderDelegate {
    private let recorder: AVAudioRecorder
    private weak var owner: VoiceRecorder?

    init(url: URL, owner: VoiceRecorder) throws {
        let session = AVAudioSession.sharedInstance()
        let channels = session.inputNumberOfChannels >= 2 ? 2 : 1
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 24,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        self.owner = owner
        super.init()
        recorder.delegate = self
        recorder.isMeteringEnabled = true
    }

    func record() -> Bool { recorder.record() }
    func pause() { recorder.pause() }
    func stop() { recorder.stop() }
    func recover() { _ = recorder.record() }
    var currentTime: TimeInterval { recorder.currentTime }

    func level() -> Float {
        recorder.updateMeters()
        return normalizedLevel(decibels: recorder.averagePower(forChannel: 0))
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "The recording couldn't be written."
        Task { @MainActor in self.owner?.backendFailed(message) }
    }
}

/// Voice Isolation takes: the engine's input with Apple's voice processing on, tapped straight
/// into an ALAC file at whatever rate the processed input runs.
@MainActor
private final class ProcessedTakeBackend: VoiceTakeBackend {
    private let engine = AVAudioEngine()
    private let sink: TapSink

    init(url: URL) throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Don't duck whatever else is playing more than iOS insists on.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceRecorderError.noInput }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey: 24,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        sink = TapSink(file: file, sampleRate: format.sampleRate)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            sink.append(buffer)
        }
        // Voice processing runs the input and output units as a pair; keep the (silent) output
        // side of the graph in place so the engine will start.
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
    }

    func record() -> Bool {
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return false }
        sink.setPaused(false)
        return true
    }

    func pause() { sink.setPaused(true) }

    func stop() {
        sink.setPaused(true)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        sink.close()
    }

    func recover() {
        if !engine.isRunning { try? engine.start() }
    }

    var currentTime: TimeInterval { sink.duration }

    func level() -> Float {
        let peak = sink.takePeak()
        guard peak > 0 else { return 0 }
        return normalizedLevel(decibels: 20 * log10(peak))
    }
}

/// Written to from the audio render thread, read from the main one — hence the lock.
private final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let sampleRate: Double
    private var paused = true
    private var frames: AVAudioFramePosition = 0
    private var peak: Float = 0

    init(file: AVAudioFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused, let file else { return }
        do {
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            return
        }
        if let channel = buffer.floatChannelData?[0] {
            var bufferPeak: Float = 0
            for index in 0..<Int(buffer.frameLength) {
                bufferPeak = max(bufferPeak, abs(channel[index]))
            }
            peak = max(peak, bufferPeak)
        }
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    /// The loudest sample since the last read (so each meter tick sees everything in between).
    func takePeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    /// Dropping the last reference to an `AVAudioFile` is what finalises it on disk.
    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}
