# BUILD_NOTES

Status: full SwiftPM/xtool project delivered per the spec's module layout and Build Sequence.
No feature is stubbed — every screen/control described in the spec has a real implementation.
This app was written **without Xcode, without a Mac, and without any local Swift toolchain**
(Windows, no WSL available). It has since been **compiled for real** — via a GitHub Actions
workflow (`.github/workflows/build-ipa.yml`) running on a macOS runner with real Xcode/`xtool` —
and that process is what found and fixed the issues below (SwiftPM duplicate-resource-name
rules, a couple of Swift 6 strict-concurrency proofs, and confirmation that the iOS 26 Cinematic
capture API names guessed from the build brief don't exist in the SDK available there).

**As of commit `522f179`, `xtool dev build --ipa` succeeds** on GitHub Actions (macOS runner,
real Xcode) — see the Actions tab on the repo for the latest run. Each fix in this file was
driven by a real compiler error, not guesswork. The build produces an unsigned `.ipa`; install
it to a device with `xtool dev build --sign` (needs `xtool auth` login) or by re-signing it with
a tool like Sideloadly.

## What to do first

```
xtool dev build
```

from the project root. If anything fails, it's most likely one of the items below.

## xtool project layout — verified against xtool source

- `Package.swift` declares exactly one **library** product (`.library`, `.target`, not
  `.executableTarget`) named `TeleprompterStudio`, per `xtool new`'s generated template
  (`Sources/XToolSupport/NewCommand.swift`). `platforms` includes both `.iOS(.v17)` and
  `.macOS(.v14)` — the macOS entry is required for `swift build`/SourceKit tooling to evaluate
  the manifest even though the app only ships to iOS; this matches the stock template exactly.
- `xtool.yml` uses the real `PackSchemaBase` fields: `version: 1`, `bundleID`, `infoPath`
  (points at `Info.plist`, merged over xtool's generated defaults — NOT the Xcode-style inline
  keys the original brief implied), `iconPath` (must be a `.png`). We deliberately did **not**
  set `entitlementsPath` — nothing in this app (camera, mic, photos-add, local network,
  Bonjour) needs an entitlement, only an `Info.plist` usage-description key, so omitting it
  keeps signing as simple as the spec asked for.
- `Info.plist` supplies `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`,
  `NSPhotoLibraryAddUsageDescription`, `NSLocalNetworkUsageDescription`, and `NSBonjourServices`
  (`_tpsync._tcp` / `_tpsync._udp` for MultipeerConnectivity, `_tpweb._tcp` informational for the
  LAN server). `SyncCoordinator.serviceType` is `"tpsync"` — keep it and the Bonjour entries in
  sync if you ever rename it.
- `AppIcon.png` is a real, valid 1024×1024 RGB PNG (generated procedurally with a raw
  zlib/PNG encoder, not a placeholder file) — a simple amber lens/record-dot mark on near-black.
  Swap it for real brand art whenever you have one; nothing else depends on its content.
- Bundle ID in `xtool.yml` is `com.example.TeleprompterStudio` — change this before shipping to
  a device tied to your own Apple ID/team, same as the stock xtool template.
- Commands used throughout this note (`xtool dev build`, `xtool dev build --ipa`, `xtool dev
  build --sign`, plain `xtool dev` to build+install+run) are all real subcommands confirmed from
  `XToolSupport/DevCommand.swift` (`DevBuildCommand`, `DevRunCommand`, default subcommand `run`).

## Vendored web assets — real files, not placeholders

- `TeleprompterEngine/Resources/katex/` and `LANServer/WebResources/katex/` each contain the
  real **KaTeX 0.16.11** distribution (`katex.min.js`, `katex.min.css`, `auto-render.min.js`,
  and the full woff2 font set + LICENSE), downloaded from the official npm/jsDelivr release at
  build-authoring time and vendored as SwiftPM `.copy` resources. No CDN reference anywhere in
  the shipped HTML/JS — matches the "offline, vendored, no CDN" requirement. Only `.woff2` files
  are vendored (not `.ttf`/`.woff`); `katex.min.css`'s `@font-face` blocks list all three formats
  per Apple's usual browser-compat pattern, but iOS 17+ WKWebView always resolves `.woff2` first,
  so the missing formats are simply unused, dead `src` entries — harmless.
- `marked.min.js` (v12.0.2, MIT) is vendored the same way, used identically by the in-app
  prompter/editor WebView and the LAN web editor, so Markdown rendering is byte-identical
  everywhere per the spec's "single source of truth" requirement.
- Because `Package.swift` copies `TeleprompterEngine/Resources/katex` and
  `LANServer/WebResources/katex` as whole-directory resources, their internal relative paths
  (`katex/fonts/*.woff2` from `katex.min.css`) are preserved inside `Bundle.module`, so the CSS's
  relative font URLs resolve correctly without extra `Bundle` plumbing.

## Apple Cinematic capture — native iOS 26 API, no simulation

The workflow runs on `macos-26` (Xcode 26, iOS 26 SDK), so `CinematicVideoSupport.swift` calls
Apple's Cinematic Video API directly (`isCinematicVideoCaptureEnabled`, `simulatedAperture`,
`requiredMetadataObjectTypesForCinematicVideoCapture`, `setCinematicVideoTrackingFocus`, …),
each behind `#available(iOS 26.0, *)` since the app still deploys to iOS 17. The earlier
Objective-C-runtime bridge (needed only because the old runner's Xcode 16.4 SDK lacked the API)
and the synthetic segmentation + blur fallback are both gone.

- Cinematic only runs on Apple's supported cameras: the back **Dual Wide** and the front
  **TrueDepth**. The app normally opens the Triple camera (for its telephoto), which has no
  Cinematic formats — switching Cinematic on therefore rebuilds the session around the right
  camera (`CinematicVideoSupport.cinematicDevice(for:)`), and switching it off goes back.
- `metadataObjectTypes` is set to exactly the required list; any other set raises while
  Cinematic is on.
- When a phone/iOS can't do it, the button turns back off and a banner says why.

## Zoom

`AVCameraSession.currentZoom`/`zoomPresets` are in stock-Camera units (1× = main wide lens). On
virtual multi-lens cameras a raw `videoZoomFactor` of 1.0 is the ultra-wide, so 1× is the first
`virtualDeviceSwitchOverVideoZoomFactors` entry; it is re-applied after every device/format change
(those reset zoom). Pinch and the lens button only work when Studio Settings → Zoom Control is on
(off by default, stored in `UserDefaults`).

## Design decisions worth knowing about

- **Concurrency**: the project builds with `swiftLanguageMode(.v6)` (strict concurrency).
  `AVCameraSession` is deliberately **not** `@MainActor` — `AVCaptureSession` configuration must
  happen off the main thread per Apple's own guidance, so the class does all
  `AVCaptureSession`/`AVCaptureDevice` mutation on a private serial `sessionQueue` and is marked
  `@unchecked Sendable` (the standard pattern for wrapping non-`Sendable` AVFoundation types);
  every write to an `@Observable` published property (`facing`, `isConfigured`, `currentZoom`,
  etc.) is explicitly bounced to the main actor so SwiftUI only ever observes main-thread
  changes. `SyncCoordinator`'s `MCSessionDelegate`/advertiser/browser delegate methods are
  `nonisolated` (required, since MultipeerConnectivity calls them off-main) and hop into
  `Task { @MainActor in ... }` before touching state.
- **Cinematic records through the same `AVCaptureMovieFileOutput` as plain video** — it's the
  movie-file path with `isCinematicVideoCaptureEnabled` on; Apple bakes the depth track in.
- **One `AVCaptureVideoDataOutput` delegate, two consumers**: both the Companion live-preview
  streamer and the synthetic cinematic compositor need every camera frame, but
  `AVCaptureVideoDataOutput` only supports a single delegate. `CameraKit/VideoFrameMultiplexer`
  fans one delegate callback out to both, each independently responsible for not blocking it.
- **Adaptive preview streaming** (`SyncKit/AdaptivePreviewStreamer`) uses a simple hysteresis
  ladder (JPEG quality → fps → resolution → fully off) driven by measured encode time vs. frame
  budget, and calls back to disable streaming (Companion falls back to "prompter mirror only")
  rather than ever letting frames back up and stall capture.
- **LAN HTTP server** is hand-rolled directly on `Network.framework` (`NWListener`/`NWConnection`)
  with a minimal HTTP/1.1 parser in `LANServer/HTTPTypes.swift` — genuinely zero external
  dependencies, per the "xtool can't build C-target/binary packages" constraint. It's
  intentionally simple (one request per connection, `Connection: close`) since it's a
  same-LAN script editor, not a production API server.
- **QR code** for the LAN URL is generated with Core Image's built-in `CIFilter.qrCodeGenerator`
  — no third-party QR library needed.
- **Editor toolbar** operates on a `UITextView`-backed `MarkdownTextView` (not SwiftUI's
  `TextEditor`, which doesn't expose text selection on iOS 17) so bold/italic/highlight/color/
  heading/alignment/math toolbar buttons can wrap the actual selected range. Underline/color/
  highlight are emitted as inline HTML (`<u>`, `<span style="color:...">`, `<mark
  style="background-color:...">`) since Markdown has no native syntax for them; `marked.js`
  passes raw HTML through by default, so they render identically in-app and in the LAN web
  editor.

## Known simplification vs. spec text

- Root navigation uses a `TabView` (Scripts / Settings) rather than a `NavigationSplitView`
  sidebar. This is still fully adaptive (works correctly on iPhone, iPad, and in Stage Manager/
  multitasking) and keeps Studio's full-screen camera experience unencumbered by split-view
  chrome; a sidebar-style iPad layout would be a straightforward follow-up if you want the
  iPad-specific chrome to look more Mac-Catalyst-like.

## Suggested first-build checklist

1. `xtool dev build` — fix any mechanical Swift errors (wrong argument label, etc.) file by file;
   the architecture/module boundaries should not need to change.
2. If `RealCinematicController`'s commented call doesn't match the real SDK, fix just that one
   line — everything else in the cinematic pipeline is unaffected.
3. Replace `AppIcon.png` and the `bundleID` in `xtool.yml` with your own before distributing.
4. `xtool dev build --sign` (requires `xtool auth` login) or `xtool dev` to install straight to a
   connected device.
