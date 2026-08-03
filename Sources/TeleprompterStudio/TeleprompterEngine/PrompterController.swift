import Foundation
import Observation

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
    var speedPxPerSec: Double = 90
    var fontSize: Double = 46
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

    func loadDocument(_ document: PrompterDocument) {
        fontSize = document.baseSize
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

    func setSpeed(_ pxPerSec: Double) { speedPxPerSec = pxPerSec }
    func setFontSize(_ size: Double) { fontSize = size }

    func setMirror(horizontal: Bool, vertical: Bool) {
        mirrorHorizontal = horizontal
        mirrorVertical = vertical
    }

    func setGuide(_ mode: PrompterGuideMode) {
        guideMode = mode
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

    /// Called by `NativePrompterView` when autoscroll reaches the end of the script.
    func markFinished() {
        isPlaying = false
        progress = 1
        onDidFinish?()
    }
}
