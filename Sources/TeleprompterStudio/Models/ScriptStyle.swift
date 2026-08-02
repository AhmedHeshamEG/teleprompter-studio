import Foundation
import SwiftData
import SwiftUI

@Model
final class ScriptStyle {
    var script: Script?

    var fontName: String = "System"
    var baseSize: Double = 46
    var lineHeight: Double = 1.4

    /// Stored as hex strings (`#RRGGBB` or `#RRGGBBAA`) so they round-trip cleanly through
    /// SwiftData, the WKWebView CSS bridge, and the LAN JSON API without a Codable Color shim.
    var textColorHex: String = "#FFFFFF"
    var bgColorHex: String = "#000000"
    var accentColorHex: String = "#FF8C1A"

    var marginTop: Double = 8
    var marginBottom: Double = 8
    var marginHorizontal: Double = 6

    var mirrorHorizontal: Bool = false
    var mirrorVertical: Bool = false

    init(
        fontName: String = "System",
        baseSize: Double = 46,
        lineHeight: Double = 1.4,
        textColorHex: String = "#FFFFFF",
        bgColorHex: String = "#000000",
        accentColorHex: String = "#FF8C1A"
    ) {
        self.fontName = fontName
        self.baseSize = baseSize
        self.lineHeight = lineHeight
        self.textColorHex = textColorHex
        self.bgColorHex = bgColorHex
        self.accentColorHex = accentColorHex
    }
}

enum HexColor {
    static func color(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll(where: { $0 == "#" })
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)

        let r, g, b, a: Double
        switch s.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            return .white
        }
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    static func hex(_ color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        let r = Int((resolved.red * 255).rounded())
        let g = Int((resolved.green * 255).rounded())
        let b = Int((resolved.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
