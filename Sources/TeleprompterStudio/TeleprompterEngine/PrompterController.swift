import Foundation
import Observation

/// The prompter values a reader tunes by hand — scroll speed, font size, reading guide — stored
/// across launches.
///
/// These used to reset on every Studio open (speed back to the built-in default, font size back to
/// the script's style), so a setting you dialled in for your own reading pace had to be dialled in
/// again every single take. They're a property of *the person reading*, not of the script, which is
/// why they live in `UserDefaults` rather than on the `Script` model.
enum PrompterPreferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let speed = "prompter.speedPxPerSec"
        static let fontSize = "prompter.fontSize"
        static let guide = "prompter.guideMode"
    }

    /// Comfortable reading pace for a first-time run. The old 90 px/s default was a sprint —
    /// fine for scanning, far too fast to actually read aloud from.
    static let defaultSpeed: Double = 35
    static let defaultFontSize: Double = 46

    /// `nil` means "never set by hand", which is what lets a script's own style still choose the
    /// starting font size on a fresh install.
    static var speed: Double? {
        get { defaults.object(forKey: Key.speed) as? Double }
        set { defaults.set(newValue, forKey: Key.speed) }
    }

    static var fontSize: Double? {
        get { defaults.object(forKey: Key.fontSize) as? Double }
        set { defaults.set(newValue, forKey: Key.fontSize) }
    }

    static var guide: PrompterGuideMode? {
        get { (defaults.string(forKey: Key.guide)).flatMap(PrompterGuideMode.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: Key.guide) }
    }
}

/// Native-side state for the prompter. No WebKit, no JavaScript bridge — `NativePrompterView`
/// observes these properties directly and drives its own scroll offset. The previous
/// WKWebView + JS implementation had no reliable signal that the page had actually loaded, which
/// is why "play" could silently do nothing and styled text could show up as raw `<span>` markup;
/// this version has nothing that can fail to "become ready".
@Observable
@MainActor
final class PrompterController {
    private(set) var isPlaying = false
    var progress: Double = 0
    /// Seeded from `PrompterPreferences` (see `init`), and written back through `setSpeed` /
    /// `setFontSize` / `setGuide` — the UI binds through those setters rather than to the
    /// properties directly, so every hand adjustment is the one that gets remembered.
    var speedPxPerSec: Double = PrompterPreferences.defaultSpeed
    var fontSize: Double = PrompterPreferences.defaultFontSize
    var guideMode: PrompterGuideMode = .line
    private(set) var mirrorHorizontal = false
    private(set) var mirrorVertical = false
    private(set) var countdownSecondsRemaining: Int?

    /// Bumped (not toggled) so repeated "jump to top" taps always produce a change the view can
    /// observe, even if the scroll position is already 0.
    private(set) var jumpToTopToken = 0
    /// One-shot seek request; the view applies it then calls `clearJumpToFractionRequest()`.
    private(set) var jumpToFractionRequest: Double?

    var onDidFinish: (() -> Void)?

    private var countdownTask: Task<Void, Never>?

    init() {
        speedPxPerSec = PrompterPreferences.speed ?? PrompterPreferences.defaultSpeed
        fontSize = PrompterPreferences.fontSize ?? PrompterPreferences.defaultFontSize
        guideMode = PrompterPreferences.guide ?? .line
    }

    func loadDocument(_ document: PrompterDocument) {
        // A font size the reader chose by hand outranks the script's styled size — otherwise
        // opening any script silently threw that choice away.
        if PrompterPreferences.fontSize == nil {
            fontSize = document.baseSize
        }
        mirrorHorizontal = document.mirrorHorizontal
        mirrorVertical = document.mirrorVertical
        progress = 0
        jumpToTopToken += 1
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func jumpToTop() {
        jumpToTopToken += 1
        progress = 0
    }

    func jumpToFraction(_ fraction: Double) {
        jumpToFractionRequest = fraction
    }

    func clearJumpToFractionRequest() {
        jumpToFractionRequest = nil
    }

    func setSpeed(_ pxPerSec: Double) {
        speedPxPerSec = pxPerSec
        PrompterPreferences.speed = pxPerSec
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        PrompterPreferences.fontSize = size
    }

    func setMirror(horizontal: Bool, vertical: Bool) {
        mirrorHorizontal = horizontal
        mirrorVertical = vertical
    }

    func setGuide(_ mode: PrompterGuideMode) {
        guideMode = mode
        PrompterPreferences.guide = mode
    }

    /// Visible 3-2-1 countdown, then starts scrolling automatically — matches the old JS
    /// behavior of `Prompter.startCountdown`, just driven natively.
    func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        countdownSecondsRemaining = seconds
        countdownTask = Task { [weak self] in
            guard let self, seconds > 0 else { return }
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
                self.countdownSecondsRemaining = remaining > 0 ? remaining : nil
            }
            self.play()
        }
    }

    /// Aborts a running 3-2-1 without starting playback (used when the take is called off).
    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownSecondsRemaining = nil
    }

    /// Called by `NativePrompterView` when autoscroll reaches the end of the script.
    func markFinished() {
        isPlaying = false
        progress = 1
        onDidFinish?()
    }
}
