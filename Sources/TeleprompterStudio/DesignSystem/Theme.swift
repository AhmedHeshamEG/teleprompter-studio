import SwiftUI

/// Central design tokens for Teleprompter Studio: dark, high-contrast, camera-first.
enum Theme {
    // MARK: Colors

    static let background = Color(red: 0.043, green: 0.043, blue: 0.055)      // #0B0B0E
    static let surface = Color(red: 0.086, green: 0.086, blue: 0.102)         // #16161A
    static let surfaceElevated = Color(red: 0.125, green: 0.125, blue: 0.145) // #202025
    static let border = Color.white.opacity(0.08)

    /// The single restrained accent color used across the whole app.
    static let accent = Color(red: 1.0, green: 0.549, blue: 0.102)            // #FF8C1A amber
    static let record = Color(red: 0.95, green: 0.20, blue: 0.20)             // recording red
    static let success = Color(red: 0.30, green: 0.85, blue: 0.55)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    // MARK: Metrics

    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusMedium: CGFloat = 14
    static let cornerRadiusLarge: CGFloat = 22

    /// Minimum thumb-reachable control edge, per spec: "large thumb-reachable controls".
    static let minControlSize: CGFloat = 52
    static let minControlSizeCompact: CGFloat = 44

    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 40

    // MARK: Animation

    static let quickSpring = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let smoothSpring = Animation.spring(response: 0.45, dampingFraction: 0.9)
}

extension ShapeStyle where Self == Color {
    static var themeBackground: Color { Theme.background }
    static var themeSurface: Color { Theme.surface }
    static var themeAccent: Color { Theme.accent }
}
