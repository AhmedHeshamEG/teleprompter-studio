# Teleprompter Studio

A native iOS/iPadOS teleprompter and camera studio for creators — write or paste a script, read it as
smoothly scrolling rich text (color, bold/italic, LaTeX math) overlaid on a live camera preview, and
either record the take in-app or run prompt-only while filming with another camera.

Built entirely in Swift/SwiftUI as a SwiftPM package compiled with [xtool](https://github.com/xtool-org/xtool)
— **without Xcode, without a Mac, and without a local Swift toolchain.** See [`BUILD_NOTES.md`](BUILD_NOTES.md)
for the full story of how that worked and the tradeoffs it forced.

## Features

- **Native teleprompter** — a TextKit-backed `UITextView` scrolled by a `CADisplayLink`, so playback
  is GPU-smooth, costs no SwiftUI re-render per frame, and renders correctly at any font size on a
  script of any length (a `UILabel` can't: past the GPU's maximum texture height it silently draws
  nothing). Scripts are authored with bold/italic/underline/color/highlight and LaTeX math via
  bundled, offline [KaTeX](https://katex.org) (no CDN, no network dependency).
- **Two run modes**: *Record* (the app is the camera and records the take) or *Prompt-only* (just the
  reader, for filming with a separate camera/app).
- **Real Cinematic capture** on supported hardware (iPhone 13+, iOS 26+) via `AVCaptureDeviceInput`'s
  Cinematic Video API — including the system's own subject detection (tracked subjects are drawn over
  the preview), **tap-to-rack-focus** with strong/weak focus styles, the format's real simulated-aperture
  range, Cinematic Extended Enhanced stabilization, and the system's "more light needed" scene warning.
  The API is reached at runtime through the Objective-C runtime (selectors discovered by scanning the
  class method lists, not by guessing names), so the project still builds on SDKs that don't expose
  those symbols yet, and reports *why* it fell back when the hardware path can't engage.
- **Synthetic cinematic fallback** everywhere else: live Vision person segmentation + Core Image
  background blur, composited frame-by-frame and recorded with `AVAssetWriter`.
- **Director/Companion sync** — mirror the prompter and a live camera preview to a second iPhone/iPad over
  the same Wi-Fi with **MultipeerConnectivity**: no internet, no login, no pairing code.
- **LAN script editor** — edit scripts from a laptop browser on the same network via a hand-rolled HTTP
  server built directly on Apple's `Network` framework (zero external dependencies), with an in-app QR
  code for the URL.
- **Local persistence** with SwiftData; scripts organized into folders with search.
- Universal, adaptive layout for iPhone and iPad, portrait and landscape, Stage Manager–aware.

## Requirements

- iOS / iPadOS 17.0+
- Xcode/macOS **not required to build** — this is a pure SwiftPM project built with `xtool`. (A Mac with
  Xcode also works fine if you have one; it's just not required.)

## Getting the app

- **Prebuilt**: grab the unsigned `.ipa` from the [Releases](../../releases) page, or the latest
  `TeleprompterStudio-ipa` artifact from the [`Build IPA`](.github/workflows/build-ipa.yml) GitHub Actions
  workflow, and sideload it (e.g. with `xtool dev build --sign` or [Sideloadly](https://sideloadly.io)).
- **Build it yourself**: see below.

## Building

```bash
xtool dev build          # build
xtool dev build --ipa    # produce an unsigned .ipa
xtool dev build --sign   # sign and install to a connected device (needs `xtool auth` login)
xtool dev                # build + install + run in one step
```

Before shipping to your own device, replace `bundleID` in [`xtool.yml`](xtool.yml) and
[`AppIcon.png`](AppIcon.png) with your own — see [`BUILD_NOTES.md`](BUILD_NOTES.md) for the full
first-build checklist and every non-obvious decision behind the project layout.

## Project structure

```
Sources/TeleprompterStudio/
├── App/                 entry point, root navigation
├── ScriptLibrary/       home: list/CRUD/paste, folders, search
├── Editor/              rich-text + LaTeX authoring
├── TeleprompterEngine/  WKWebView renderer + scroll controller
├── CameraKit/           AVFoundation session, real + synthetic cinematic
├── Recorder/            AVAssetWriter / movie output, prompt-only bypass
├── SyncKit/             MultipeerConnectivity Director/Companion sync
├── LANServer/           Network.framework HTTP server + web editor
├── DesignSystem/        shared design tokens
├── Models/              SwiftData models
└── SharedWebResources/  vendored marked.js / KaTeX, shared across in-app and LAN web views
```

## License

[MIT](LICENSE)
