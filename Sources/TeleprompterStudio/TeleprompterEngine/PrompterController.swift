import Foundation
import Observation
import WebKit

/// Native-side handle for driving the prompter WKWebView. Owns no UIKit/WebKit types directly
/// visible to callers beyond a weak reference set by `PrompterWebView`'s coordinator, so view
/// models can hold a `PrompterController` without importing WebKit.
@Observable
@MainActor
final class PrompterController {
    weak var webView: WKWebView?

    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    var speedPxPerSec: Double = 90
    var fontSize: Double = 46
    var guideMode: PrompterGuideMode = .line

    var onDidFinish: (() -> Void)?
    var onReady: (() -> Void)?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func handleMessage(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            onReady?()
        case "progress":
            if let value = body["value"] as? Double { progress = value }
            if let playing = body["playing"] as? Bool { isPlaying = playing }
        case "playState":
            if let playing = body["playing"] as? Bool { isPlaying = playing }
        case "didFinish":
            isPlaying = false
            onDidFinish?()
        case "countdownComplete":
            isPlaying = true
        default:
            break
        }
    }

    func loadDocument(_ document: PrompterDocument) {
        setStyle(document)
        setContent(document.markdown)
        setMirror(horizontal: document.mirrorHorizontal, vertical: document.mirrorVertical)
    }

    func setContent(_ markdown: String) {
        run("Prompter.setContent(\(Self.jsString(markdown)))")
    }

    func setStyle(_ document: PrompterDocument) {
        let json: [String: Any] = [
            "textColor": document.textColorHex,
            "bgColor": document.bgColorHex,
            "accentColor": document.accentColorHex,
            "baseSize": document.baseSize,
            "lineHeight": document.lineHeight,
            "marginH": document.marginHorizontalPercent,
            "fontName": document.fontName,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let jsonString = String(data: data, encoding: .utf8) {
            run("Prompter.setStyle(\(jsonString))")
        }
        fontSize = document.baseSize
    }

    func play() {
        run("Prompter.play()")
        isPlaying = true
    }

    func pause() {
        run("Prompter.pause()")
        isPlaying = false
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func jumpToTop() {
        run("Prompter.jumpToTop()")
    }

    func jumpToFraction(_ fraction: Double) {
        run("Prompter.jumpToFraction(\(fraction))")
    }

    func setSpeed(_ pxPerSec: Double) {
        speedPxPerSec = pxPerSec
        run("Prompter.setSpeed(\(pxPerSec))")
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        run("Prompter.setFontSize(\(size))")
    }

    func setMirror(horizontal: Bool, vertical: Bool) {
        run("Prompter.setMirror(\(horizontal), \(vertical))")
    }

    func setGuide(_ mode: PrompterGuideMode) {
        guideMode = mode
        run("Prompter.setGuide(\(Self.jsString(mode.rawValue)))")
    }

    func startCountdown(seconds: Int) {
        run("Prompter.startCountdown(\(seconds))")
    }

    private func run(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // encoded is like ["the string"] — strip the array brackets.
        return String(encoded.dropFirst().dropLast())
    }
}
