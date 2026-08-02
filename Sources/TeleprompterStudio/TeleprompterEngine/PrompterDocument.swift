import Foundation

/// Everything the WKWebView renderer needs to draw a script, decoupled from the SwiftData
/// `Script`/`ScriptStyle` models so `TeleprompterEngine` has no persistence dependency.
struct PrompterDocument: Equatable {
    var markdown: String
    var fontName: String
    var baseSize: Double
    var lineHeight: Double
    var textColorHex: String
    var bgColorHex: String
    var accentColorHex: String
    var marginHorizontalPercent: Double
    var mirrorHorizontal: Bool
    var mirrorVertical: Bool

    init(
        markdown: String,
        fontName: String = "System",
        baseSize: Double = 46,
        lineHeight: Double = 1.4,
        textColorHex: String = "#FFFFFF",
        bgColorHex: String = "#000000",
        accentColorHex: String = "#FF8C1A",
        marginHorizontalPercent: Double = 6,
        mirrorHorizontal: Bool = false,
        mirrorVertical: Bool = false
    ) {
        self.markdown = markdown
        self.fontName = fontName
        self.baseSize = baseSize
        self.lineHeight = lineHeight
        self.textColorHex = textColorHex
        self.bgColorHex = bgColorHex
        self.accentColorHex = accentColorHex
        self.marginHorizontalPercent = marginHorizontalPercent
        self.mirrorHorizontal = mirrorHorizontal
        self.mirrorVertical = mirrorVertical
    }

    init(markdown: String, style: ScriptStyle) {
        self.init(
            markdown: markdown,
            fontName: style.fontName,
            baseSize: style.baseSize,
            lineHeight: style.lineHeight,
            textColorHex: style.textColorHex,
            bgColorHex: style.bgColorHex,
            accentColorHex: style.accentColorHex,
            marginHorizontalPercent: style.marginHorizontal,
            mirrorHorizontal: style.mirrorHorizontal,
            mirrorVertical: style.mirrorVertical
        )
    }
}

enum PrompterGuideMode: String {
    case line, band, none
}
