// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeleprompterStudio",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "TeleprompterStudio",
            targets: ["TeleprompterStudio"]
        ),
    ],
    targets: [
        .target(
            name: "TeleprompterStudio",
            resources: [
                .copy("TeleprompterEngine/Resources/prompter.html"),
                .copy("TeleprompterEngine/Resources/prompter.css"),
                .copy("TeleprompterEngine/Resources/prompter.js"),
                .copy("LANServer/WebResources/editor.html"),
                .copy("LANServer/WebResources/editor.css"),
                .copy("LANServer/WebResources/editor.js"),
                // Shared once here (not duplicated per-consumer) because SwiftPM requires
                // resource basenames to be unique within a target, even across subdirectories.
                .copy("SharedWebResources/marked.min.js"),
                .copy("SharedWebResources/katex"),
                // OpenDyslexic (SIL OFL), registered with Core Text at launch — see PrompterFonts.
                .copy("Resources/Fonts"),
            ],
            // Swift 6 tools/syntax, but Swift 5 language mode: relaxed (non-strict) actor
            // isolation checking, matching how most shipping iOS apps build today. See
            // BUILD_NOTES.md "Concurrency" for the handful of spots that were written with
            // strict-mode discipline anyway (explicit main-actor hops via Task/DispatchQueue).
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
