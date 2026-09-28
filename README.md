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
- **A prompter card you place, not one that places you** — drag its handle to move it, its corner grip
  or a two-finger pinch to resize; the gestures run in UIKit, so a drag moves one view's frame instead
  of re-rendering the screen 60 times a second. One button sweeps every other control off the display
  (leaving the script, the transport, the take timer and the record button), and in landscape the
  chrome lives in side rails, because a landscape iPhone has ~390 points of height and none to spare.
- **Voice mode**: the same script and prompter with the camera swapped for a recorder built like
  Voice Memos. It has a live waveform, a clock to the hundredth of a second, pause/resume into the
  same file, and discard. Each script has a takes list with a scrubbable waveform player (±5 s,
  playback speed, rename, share, swipe to delete), and playback shows up on the Lock Screen and in
  Control Center via Now Playing. Recording is Apple Lossless (ALAC), 24-bit. You pick the mic in
  Apple's own input picker on iOS 26, and AirPods record at full quality on iOS 26. **Voice
  Isolation** is opt-in (off by default, in the ⋯ menu). Turning it on records through Apple's voice
  processing, and the mode is set in the system's Mic Mode panel. Takes keep recording if the screen
  locks, and they land in the Files app (On My iPhone → Teleprompter Studio → Recordings).
- **Notebook scripts** — drop photos into a script from the editor's toolbar; they show inline in the
  editor, on the prompter (centred, sized to the card) and in the laptop editor's preview. Lines
  starting with `>` are *cues*, set smaller in the script's accent colour so a stage direction never
  reads as a line to say. Pictures live in the Markdown as `![](tp-image:…)` links, so no stored
  script changed shape.
- **The phone stays awake** while Studio, Voice or Companion is open — a phone on a tripod gets no
  touches, and auto-lock used to end the take.
- **Dyslexia-friendly typesetting** — bundled [OpenDyslexic](https://opendyslexic.org) (SIL OFL),
  selectable per script from Studio Settings or the editor's Style panel, with line spacing derived from
  the font's own metrics.
- **4K/30 capture by default**, walking down to the nearest format the camera actually has (and saying
  so on screen) rather than silently recording something else.
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
- **Director/Companion sync**: mirror the prompter, its pictures and a live camera preview to a
  second iPhone/iPad over **MultipeerConnectivity**. It works on the local network, with no internet,
  no login and no pairing code. After you pair once, the two devices remember each other and relink
  on their own, with no prompt. That happens at launch, whenever either app comes back to the
  foreground, and through a retry watchdog. A Companion that was closed reopens as the Companion and
  keeps its script on screen while the link comes back. (iOS doesn't let any app hold a link open
  while it's closed or the phone is locked, so the link heals on reopen instead.)
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
