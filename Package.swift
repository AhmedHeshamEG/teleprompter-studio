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
                .copy("TeleprompterEngine/Resources/marked.min.js"),
                .copy("TeleprompterEngine/Resources/katex"),
                .copy("LANServer/WebResources/editor.html"),
                .copy("LANServer/WebResources/editor.css"),
                .copy("LANServer/WebResources/editor.js"),
                .copy("LANServer/WebResources/marked.min.js"),
                .copy("LANServer/WebResources/katex"),
            ]
        ),
    ]
)
