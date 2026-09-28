import AVFoundation
import MediaPlayer
import Observation

/// Plays back voice takes, Voice Memos style: scrub anywhere, skip 5 seconds either way, change
/// speed, and control it from the Lock Screen and Control Center through Apple's Now Playing.
@MainActor
@Observable
final class TakePlayer: NSObject {
    /// The take that's loaded, by `Recording.id`.
    private(set) var loadedID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1

    static let skipInterval: TimeInterval = 5
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private var player: AVAudioPlayer?
    private var title = ""
    private var ticker: Timer?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    var progress: Double { duration > 0 ? currentTime / duration : 0 }

    /// Loads a take without playing it. Loading the one already loaded keeps its position.
    @discardableResult
    func load(url: URL, id: UUID, title: String) -> Bool {
        if loadedID == id, player != nil { return true }
        unload()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        self.player = player
        self.title = title
        loadedID = id
        duration = player.duration
        currentTime = 0
        registerRemoteCommands()
        publishNowPlaying()
        return true
    }

    func unload() {
        stopTicker()
        player?.stop()
        player = nil
        loadedID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        unregisterRemoteCommands()
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startTicker()
        publishNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        syncTime()
        publishNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        syncTime()
        publishNowPlaying()
    }

    func seek(toFraction fraction: Double) {
        seek(to: duration * max(0, min(1, fraction)))
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player?.rate = newRate
        publishNowPlaying()
    }

    // MARK: Internals

    private func syncTime() {
        currentTime = player?.currentTime ?? 0
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTime() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    fileprivate func didFinish() {
        isPlaying = false
        stopTicker()
        currentTime = duration
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        guard player != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Teleprompter Studio",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
    }

    /// Lock Screen / Control Center / AirPods controls. The handlers arrive on the main thread.
    private func registerRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { event in
                MainActor.assumeIsolated { action(event) }
                return .success
            }
            remoteTargets.append((command, target))
        }
        add(center.playCommand) { [weak self] _ in self?.play() }
        add(center.pauseCommand) { [weak self] _ in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipForwardCommand) { [weak self] _ in self?.skip(by: Self.skipInterval) }
        add(center.skipBackwardCommand) { [weak self] _ in self?.skip(by: -Self.skipInterval) }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
            }
        }
    }

    private func unregisterRemoteCommands() {
        for (command, target) in remoteTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        remoteTargets.removeAll()
    }
}

extension TakePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.didFinish() }
    }
}

/// Reads a take's loudness envelope for drawing: `bars` values, 0…1. Samples a short window at
/// each bar rather than decoding the whole file, so an hour-long take draws as fast as a short one.
enum WaveformLoader {
    static func load(url: URL, bars: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            guard bars > 0, let file = try? AVAudioFile(forReading: url) else { return [] }
            let length = file.length
            guard length > 0 else { return [] }
            let format = file.processingFormat
            let window = AVAudioFrameCount(min(max(length / AVAudioFramePosition(bars), 1), 4096))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return [] }
            var values: [Float] = []
            values.reserveCapacity(bars)
            for bar in 0..<bars {
                file.framePosition = length * AVAudioFramePosition(bar) / AVAudioFramePosition(bars)
                buffer.frameLength = 0
                guard (try? file.read(into: buffer, frameCount: window)) != nil,
                      let channel = buffer.floatChannelData?[0], buffer.frameLength > 0
                else {
                    values.append(0)
                    continue
                }
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let decibels = rms > 0 ? 20 * log10(rms) : -80
                values.append(max(0, min(1, (decibels + 50) / 50)))
            }
            return values
        }.value
    }
}
