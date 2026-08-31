import CoreText
import SwiftUI
import UIKit

/// The typefaces the prompter can be read in.
///
/// Deliberately short. A prompter is read at a glance from a metre away while you're talking, so
/// the choice that matters isn't "which of 40 fonts" but "the normal one, or the one built for
/// people who find normal type hard to track". Everything else here is a face that already ships
/// with iOS, so the list stays valid on every device.
enum PrompterTypeface: String, CaseIterable, Identifiable {
    case system = "System"
    case openDyslexic = "OpenDyslexic"
    case georgia = "Georgia"
    case avenirNext = "Avenir Next"
    case courierNew = "Courier New"

    var id: String { rawValue }

    /// What to show in a picker — the OpenDyslexic row says what it's for, because "OpenDyslexic"
    /// means nothing to someone who hasn't met it.
    var displayName: String {
        switch self {
        case .openDyslexic: return "OpenDyslexic (dyslexia-friendly)"
        default: return rawValue
        }
    }

    /// The two faces offered in Studio's on-set settings. The full list stays available in the
    /// editor's Script Style panel; mid-shoot you want the choice you actually make, not a menu.
    static let studioChoices: [PrompterTypeface] = [.system, .openDyslexic]

    init(fontName: String) {
        self = PrompterTypeface(rawValue: fontName) ?? .system
    }
}

/// Resolves a stored `ScriptStyle.fontName` to a real `UIFont`, and registers the bundled faces.
enum PrompterFonts {
    /// PostScript names as they appear in the bundled OTFs' name tables (verified against the
    /// files, not guessed — `UIFont(name:)` matches on PostScript name, not family name).
    private static let openDyslexicRegular = "OpenDyslexic-Regular"
    private static let openDyslexicBold = "OpenDyslexic-Bold"

    /// Registers the OTFs shipped in the SwiftPM resource bundle with Core Text.
    ///
    /// Done at runtime rather than through `Info.plist`'s `UIAppFonts`: SwiftPM puts resources in
    /// a nested `.bundle`, not at the app bundle's root, which is the only place `UIAppFonts`
    /// looks — so the plist route would silently register nothing and the prompter would fall
    /// back to the system face with no sign of why.
    static func registerBundledFonts() {
        guard !hasRegistered else { return }
        hasRegistered = true
        for url in bundledFontURLs() {
            var error: Unmanaged<CFError>?
            // `.process` scope: visible to this process only, which is all an app needs and
            // avoids asking the user for anything.
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                error?.release()
            }
        }
    }

    private nonisolated(unsafe) static var hasRegistered = false

    private static func bundledFontURLs() -> [URL] {
        let bundle = Bundle.module
        // `.copy("Resources/Fonts")` keeps the directory, so the fonts live in a `Fonts`
        // subdirectory; the flat lookup is a fallback in case a future build flattens it.
        var urls = bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? []
        if urls.isEmpty {
            urls = bundle.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
        }
        return urls
    }

    /// The font the prompter renders with. Prompter text is set semibold — at reading distance,
    /// over a live camera image, regular weight loses its edges against a bright background.
    static func uiFont(named fontName: String, size: CGFloat) -> UIFont {
        registerBundledFonts()
        switch PrompterTypeface(fontName: fontName) {
        case .system:
            return .systemFont(ofSize: size, weight: .semibold)
        case .openDyslexic:
            // OpenDyslexic's weighted baselines are the point of it; Bold is what reads at
            // prompter distance, and Regular covers a device where Bold failed to register.
            return UIFont(name: openDyslexicBold, size: size)
                ?? UIFont(name: openDyslexicRegular, size: size)
                ?? .systemFont(ofSize: size, weight: .semibold)
        case .georgia, .avenirNext, .courierNew:
            guard let base = UIFont(name: fontName, size: size) else {
                return .systemFont(ofSize: size, weight: .semibold)
            }
            guard let bold = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
            return UIFont(descriptor: bold, size: size)
        }
    }

    /// SwiftUI-side equivalent, for previews and the style panel's sample row.
    static func font(named fontName: String, size: CGFloat) -> Font {
        Font(uiFont(named: fontName, size: size))
    }
}
