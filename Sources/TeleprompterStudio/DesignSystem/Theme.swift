import SwiftUI

/// Central design tokens for Teleprompter Studio: dark, high-contrast, camera-first.
enum Theme {
    // MARK: Colors
    //
    // Apple's own dark palette (the values iOS uses for systemBackground, secondarySystemBackground,
    // systemYellow, systemRed… in dark mode), so the custom chrome sits next to the system's Liquid
    // Glass bars and sheets without looking like it came from a different app.

    static let background = Color.black
    static let surface = Color(red: 0.110, green: 0.110, blue: 0.118)         // #1C1C1E
    static let surfaceElevated = Color(red: 0.173, green: 0.173, blue: 0.180) // #2C2C2E
    static let border = Color.white.opacity(0.10)

    /// The single accent: the yellow the stock Camera app uses for anything that's switched on
    /// (and Notes uses for its tint).
    static let accent = Color(red: 1.0, green: 0.839, blue: 0.039)            // #FFD60A
    static let record = Color(red: 1.0, green: 0.271, blue: 0.227)            // #FF453A
    static let success = Color(red: 0.188, green: 0.820, blue: 0.345)         // #30D158
    /// Advisory, not failure: a condition the shot can still be taken under (the system asking for
    /// more light during a Cinematic take, say). Orange, so a warning doesn't read as just another
    /// switched-on control in accent yellow.
    static let warning = Color(red: 1.0, green: 0.624, blue: 0.039)           // #FF9F0A

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    // MARK: Metrics

    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusMedium: CGFloat = 16
    static let cornerRadiusLarge: CGFloat = 24

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

extension View {
    /// Floating chrome over the camera or the script: Liquid Glass on iOS 26, the system's thin
    /// material before it. `tint` colours the glass for a switched-on control.
    @ViewBuilder
    func chromeGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self
                .background {
                    if let tint {
                        shape.fill(tint)
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
                .overlay(shape.stroke(Theme.border, lineWidth: 1))
        }
    }
}
