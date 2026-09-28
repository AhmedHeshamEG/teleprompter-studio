import AVFoundation
import Observation
import SwiftData

/// The voice side of the app: a lossless audio recorder for reading a script without a camera.
///
/// Everything here is stock AVFoundation — `AVAudioSession` for the route and the mic, and
/// `AVAudioRecorder` writing **Apple Lossless (ALAC), 48 kHz, 24-bit** into an `.m4a`. Lossless
/// means what the mic heard is what's in the file: no AAC smearing on sibilants, nothing baked in
/// that an edit can't undo. Takes are written straight into Documents/Recordings — not a temp file
/// moved at the end — so a crash or a call mid-take still leaves everything up to that point on
/// disk, and that folder is visible in the Files app.
@MainActor
@Observable
final class VoiceRecorder: NSObject {
    private(set) var isRecording = false
    /// The system paused the take (a phone call, Siri, an alarm). It resumes on its own when the
    /// interruption ends, if iOS says it may.
    private(set) var isInterrupted = false
    private(set) var elapsed: TimeInterval = 0
    /// Input level, 0…1, for the meter. Updated ~20× a second while recording or armed.
    private(set) var level: Float = 0
    private(set) var inputName = ""
    private(set) var inputs: [AVAudioSessionPortDescription] = []
    private(set) var lastTake: URL?
    private(set) var isPlayingLastTake = false
    var errorMessage: String?
    var isPermissionDenied = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
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
        let session = AVAudioSession.sharedInstance()
        do {
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
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try? session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        } catch {
            errorMessage = "Couldn't open the microphone: \(error.localizedDescription)"
            return false
        }
        observeSession()
        refreshInputs()
        startMetering()
        return true
    }

    func teardown() {
        if isRecording { _ = stop() }
        player?.stop()
        player = nil
        isPlayingLastTake = false
        stopMetering()
        recorder = nil
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
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            // iOS has already paused the recorder; the file so far is safe on disk.
            if isRecording { isInterrupted = true }
        case .ended:
            guard isInterrupted else { return }
            isInterrupted = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                recorder?.record()
            } else {
                errorMessage = "Recording paused by iOS. Tap stop to keep the take."
            }
        @unknown default:
            break
        }
    }

    // MARK: Recording

    func start(scriptTitle: String) throws {
        guard !isRecording else { return }
        stopPlayback()
        let url = try Self.newTakeURL(scriptTitle: scriptTitle)
        let session = AVAudioSession.sharedInstance()
        let channels = session.inputNumberOfChannels >= 2 ? 2 : 1
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 24,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: url)
            throw VoiceRecorderError.couldNotStart
        }
        self.recorder = recorder
        currentTakeURL = url
        isRecording = true
        isInterrupted = false
        elapsed = 0
    }

    /// Ends the take and returns its file.
    func stop() -> URL? {
        guard isRecording, let recorder else { return nil }
        elapsed = recorder.currentTime
        recorder.stop()
        isRecording = false
        isInterrupted = false
        self.recorder = nil
        lastTake = currentTakeURL
        currentTakeURL = nil
        return lastTake
    }

    /// Records the finished take in the library alongside the script's video takes.
    func saveTake(_ url: URL, duration: TimeInterval, script: Script, in context: ModelContext) {
        let recording = Recording(
            script: script,
            relativePath: url.lastPathComponent,
            durationSec: duration,
            resolutionWidth: 0,
            resolutionHeight: 0
        )
        context.insert(recording)
        try? context.save()
    }

    // MARK: Playback of the last take

    func togglePlayback() {
        if isPlayingLastTake {
            stopPlayback()
            return
        }
        guard let lastTake, let player = try? AVAudioPlayer(contentsOf: lastTake) else { return }
        player.delegate = self
        player.play()
        self.player = player
        isPlayingLastTake = true
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlayingLastTake = false
    }

    // MARK: Metering

    /// Reads the live take's level; between takes the meter settles to rest.
    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMeter() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func tickMeter() {
        guard let recorder, recorder.isRecording else {
            if level != 0 { level = max(0, level - 0.08) }
            return
        }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        // -50 dB and below reads as silence; 0 dB is full scale.
        let normalized = max(0, min(1, (decibels + 50) / 50))
        level = normalized
        elapsed = recorder.currentTime
    }

    private static func newTakeURL(scriptTitle: String) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeTitle = scriptTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
            .prefix(60)
        let name = "\(safeTitle.isEmpty ? "Voice" : String(safeTitle)) \(formatter.string(from: Date())).m4a"
        return directory.appendingPathComponent(name)
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "The recording couldn't be written."
        Task { @MainActor in
            self.errorMessage = message
            _ = self.stop()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlayingLastTake = false }
    }
}

enum VoiceRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "The microphone didn't start. Check that no other app is using it, then try again."
        }
    }
}
