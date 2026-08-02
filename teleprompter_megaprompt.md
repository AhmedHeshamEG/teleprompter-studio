# BUILD PROMPT — "Native Teleprompter Studio" (iOS + iPadOS, built WITHOUT Xcode)

You are an expert Apple-platform engineer working on **Windows via Claude Code**, with **no Mac and no Xcode**. Build a **complete, production-quality, native iOS + iPadOS app** as a **Swift Package Manager (SwiftPM) app compiled with `xtool`** — not an Xcode project. Ship real, working Swift — no placeholders, no `// TODO`, no stub functions. Where a feature is device-gated, implement the real path AND the fallback. Swift 6, SwiftUI. Deployment target **iOS 17.0** minimum, with iOS 26 features gated behind availability checks.

Read the whole spec before writing code, then follow the **Build Sequence** at the bottom so the package compiles at every stage under `xtool dev build`.

---

## 0. BUILD ENVIRONMENT & TOOLCHAIN (this constrains everything below)

The app is built and deployed with **xtool** (github.com/xtool-org/xtool) from Windows (inside WSL2 / Ubuntu). This is NOT an Xcode project. Respect these hard constraints or the build fails:

- **SwiftPM package only.** Structure: `Package.swift` + `xtool.yml` + `Sources/<AppName>/...`. No `.xcodeproj`, no `.xcworkspace`, no schemes, no CocoaPods, no Carthage.
- **Info.plist keys, bundle id, app icon, and entitlements are all configured in `xtool.yml`** (not an Xcode target editor). Generate a correct `xtool.yml` with every permission this app needs.
- **Dependencies must be pure-Swift source packages only.** No binary `.xcframework` dependencies, no packages with C targets that need Xcode tooling. When in doubt, use an Apple **system framework** and write it yourself.
- **No asset catalogs (`.xcassets`).** They need Xcode's `actool`. Instead: use **SF Symbols** for all icons, and ship images/HTML/JS as **SwiftPM resource files** (`.copy`/`.process` in `Package.swift`), loaded from `Bundle.module`. App icon is provided via `xtool.yml` as a PNG.
- **Build/run commands** the code must be compatible with: `xtool dev build` (build), `xtool dev build --ipa` (produce signed .ipa), and deploy to a USB-connected iPhone. The iOS Simulator path (`xtool dev run -s`) is macOS-only and unavailable here, so **the app must be testable on a physical device** — do not rely on simulator-only behavior.
- **Signing**: via Apple ID through xtool. Assume the developer has an Apple Developer account. Keep required entitlements minimal and standard (camera, mic, local network) so signing succeeds; do not add entitlements the app doesn't truly need.

If any single capability cannot be built under xtool, isolate it behind a protocol with a working default, note it clearly in a `BUILD_NOTES.md`, and keep the rest of the app compiling and running.

---

## 1. WHAT THE APP IS

A professional teleprompter + camera studio for creators. The user writes/pastes scripts, then reads them as scrolling rich text (color, bold/italic, LaTeX math) overlaid on a live camera preview. The app can **record** the video itself (with real Cinematic mode where supported, or a synthetic depth-of-field effect elsewhere), OR run **prompt-only** while the user films in another app. A second Apple device (iPad or another iPhone) mirrors the teleprompter and acts as a live monitor + remote — synced peer-to-peer over the same Wi-Fi with **no internet and no login**. Scripts can also be edited from a laptop browser on the same LAN.

**Two run modes, user-switchable:**
- **Record mode** — the app is the camera and records the take.
- **Prompt-only mode** — no recording; the app is just the reader (for filming on a separate camera/app).

---

## 2. HARD TECH DECISIONS (do not deviate)

- **100% native**: Swift + SwiftUI, as a SwiftPM app (see §0). No React Native / Flutter / web wrappers for the app shell.
- **Teleprompter renders in a `WKWebView`** loading local HTML/CSS/JS shipped as `Bundle.module` resources. This is the single source of truth for text styling: rich formatting (CSS), **LaTeX via bundled KaTeX** (offline, vendored as resource files — no CDN), smooth GPU scrolling, identical rendering across devices and the laptop browser.
- **Camera/recording**: AVFoundation (`AVCaptureSession`, `AVCaptureMovieFileOutput` / `AVCaptureVideoDataOutput` + `AVAssetWriter`). All system frameworks — fine under SwiftPM.
- **Real Cinematic capture** (iOS 26+, iPhone 13+): set `isCinematicVideoCaptureEnabled = true` on the `AVCaptureDeviceInput`; drive focus with `setCinematicVideoTrackingFocus(detectedObjectID:focusMode:)` from detected-subject metadata; expose `CinematicVideoFocusMode` (`.none`/`.strong`/`.weak`). Gate ALL of this behind `if #available(iOS 26, *)` + a runtime capability check. Use the **Cinematic framework** for playback/edit of the depth file.
- **Synthetic "cinematic" fallback** (older iOS / unsupported hardware): person segmentation (Vision `VNGeneratePersonSegmentationRequest`, or `AVCaptureDepthDataOutput` depth where available) → Core Image / Metal background blur composited live on `AVCaptureVideoDataOutput` frames, recorded via `AVAssetWriter`. Must run at usable framerate; drop resolution before dropping frames.
- **Device-to-device sync**: **MultipeerConnectivity** (Wi-Fi/Bluetooth, same LAN, no internet). System framework. Auto-discovery, auto-reconnect.
- **Laptop access**: host a **local HTTP server built directly on Apple's `Network` framework** — **zero external dependencies** (this avoids any non-pure-Swift package that xtool can't build). Serves a script-management web page on `http://<device-ip>:<port>`. Show URL + QR code in-app. LAN only; bind to the local interface; make it toggleable.
- **Persistence**: **SwiftData** (models below) — works in a SwiftPM app on iOS 17+.
- **Universal app**: adaptive SwiftUI for iPhone + iPad; portrait + landscape; iPad multitasking/Stage Manager.

---

## 3. ARCHITECTURE (modules → Swift files/folders under `Sources/`)

```
Sources/TeleprompterStudio/
├── App/                 (entry point, root navigation)
├── ScriptLibrary/       (home: list/CRUD/paste, folders, search)
├── Editor/              (rich-text + LaTeX authoring)
├── TeleprompterEngine/  (WKWebView renderer + scroll controller)
│   └── Resources/       (prompter.html, styles.css, katex/*  — SwiftPM resources)
├── CameraKit/           (AVFoundation session, front/back, formats)
│   ├── CinematicReal/   (iOS 26+ real cinematic capture)
│   └── CinematicSynth/  (segmentation + Core Image bokeh fallback)
├── Recorder/            (AVAssetWriter / movie output, prompt-only bypass)
├── SyncKit/             (MultipeerConnectivity: roles, state, live preview stream)
├── LANServer/           (Network-framework HTTP server + web editor resources)
└── DesignSystem/        (tokens, components, theming)
```

Clean MVVM-ish structure with `@Observable` view models. Camera, sync, and server each sit behind a protocol so they're swappable and any xtool incompatibility can be stubbed without breaking the app.

---

## 4. FEATURE SPECS

### 4.1 Script Library (home)
- Grid/list: title, first line, word count, estimated read time, last-edited.
- Create, duplicate, delete, rename; folders/tags; full-text search.
- **Paste-to-create**: prominent affordance ingesting clipboard text (plain or Markdown) into a new script.
- Import from Files; export `.txt`/`.md`/`.html`.
- Editable from the laptop web page (§4.7), reflected here live.

### 4.2 Editor (rich text + LaTeX)
- Canonical content format = **Markdown + inline LaTeX** (`$...$` inline, `$$...$$` block). Portable, diffable, laptop-editable.
- Toolbar: **bold, italic, underline, highlight, text color, background color, headings, alignment, insert-math**. Colors from palette + custom picker ("colorize/colorful").
- Live preview pane using the same WebView renderer as the prompter.
- Per-script overrides: font, base size, line height, text/bg/accent colors, margins.

### 4.3 Teleprompter Engine
- `WKWebView` loads local `prompter.html` (from `Bundle.module`): Markdown → HTML, LaTeX via **bundled KaTeX**, script styling, JS scroll API.
- Native ↔ JS bridge (`WKScriptMessageHandler` + `evaluateJavaScript`): **play/pause, speed (WPM or px/s), jump to top, jump to marker, scroll position 0–1, live font-size**.
- Controls: play/pause, speed slider, font-size slider, restart, **3-2-1 countdown**, progress bar.
- **Mirror flip** (horizontal + vertical) for beam-splitter glass rigs.
- Reading guide: center line / focus band / margin masks. Idle auto-hide; tap to reveal.
- Scrolling driven by `requestAnimationFrame` in JS (not native timers) for jitter-free motion.

### 4.4 CameraKit + Recording
- Front/back toggle; resolution & fps picker (1080p/4K, 24/30/60); grid + level; tap-to-focus/expose; pinch zoom; torch.
- Teleprompter overlays live preview with adjustable opacity, height, vertical position (text near the lens for natural eyeline).
- **Record mode**: capture → save to Photos and/or app Files; timer + REC indicator.
- **Prompt-only mode**: no recording; camera preview optional; instant, obvious mode switch.

### 4.5 Cinematic layer
- Runtime capability detect. iOS 26+ AND supported device → **real Cinematic Video** with focus-mode control (auto rack-focus + tap-to-lock strong/weak on detected subjects), recording the cinematic movie file (keeps disparity/metadata).
- Else → **synthetic**: live segmentation + Core Image background blur with adjustable "aperture"/blur slider, recorded via `AVAssetWriter`. Label it as simulated in the UI.
- One unified UI (a "Cinematic" toggle + focus/blur controls); engine picks real vs synthetic underneath.

### 4.6 SyncKit (multi-device)
- **Roles**: `Director` (recording/primary) and `Companion` (iPad or 2nd iPhone). Either device can take either role; negotiate on connect.
- Companion is **all of**: (a) big **teleprompter** mirroring the Director's script + scroll position live, (b) **live monitor** of the Director's camera, (c) **remote** (play/pause, speed, font size, start/stop record).
- **Same-screen mirroring**: Director is source of truth for scroll/play-state; broadcast deltas so both screens stay locked.
- **Live preview streaming** to Companion: downscale + JPEG/HEVC-compress frames from `AVCaptureVideoDataOutput`, send over the Multipeer stream (~540p @ 15–20fps). Heaviest piece — **adaptive quality**: drop resolution/fps under pressure, never block capture; gracefully fall back to "prompter-mirror only, no live video" if throughput is poor.
- Auto-discover, status UI, auto-reconnect. Confirm before connecting; no pairing codes on same LAN.

### 4.7 LANServer (laptop script editing)
- HTTP server on Apple's `Network` framework (no external deps) serving a clean single-page web app for **script CRUD** (list, open, edit rich text + LaTeX with live preview, save). Same Markdown+LaTeX format; bundle KaTeX for the web page too so preview matches the app.
- In-app: LAN URL + **QR code**, start/stop toggle, current bound IP/port.
- Writes go straight into SwiftData, reflected live in the library and on connected devices. LAN-only.

---

## 5. DATA MODEL (SwiftData)

- `Script`: id, title, bodyMarkdown, folder?, tags[], createdAt, updatedAt, style, markers[].
- `ScriptStyle`: fontName, baseSize, lineHeight, textColor, bgColor, accentColor, margins, mirrorH, mirrorV.
- `Folder`: id, name, order.
- `Recording`: id, scriptID?, fileURL, createdAt, durationSec, isCinematic, cinematicKind (real/synth/none), cameraFacing, resolution.
- `AppSettings`: defaultSpeed, defaultStyle, lanServerEnabled, lanPort, lastRole.

---

## 6. PERMISSIONS (declare ALL of these in `xtool.yml`)

- `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`.
- `NSLocalNetworkUsageDescription` + `NSBonjourServices` (declare the Bonjour service types) — needed by BOTH MultipeerConnectivity and the LAN server.
- Idle-timer disabled during a take so the screen doesn't sleep.
- Only these entitlements; nothing that would complicate xtool signing.

---

## 7. DESIGN DIRECTION

Dark, high-contrast, camera-first. Large thumb-reachable controls; nothing tiny near edges. Prompter surface calm and legible (generous line height, comfortable measure, everything adjustable). One restrained accent color; SF Symbols throughout; Dynamic Type in chrome (prompter has its own sizing). Smooth purposeful transitions. Record state unmistakable. Real-vs-synthetic cinematic distinction shown honestly.

---

## 8. BUILD SEQUENCE (each step must `xtool dev build` clean and run on a real device)

1. **SwiftPM skeleton**: `Package.swift`, `xtool.yml`, app entry, DesignSystem, SwiftData models, navigation. Script Library + Editor working end-to-end (create/paste/edit/save, no camera). Confirm it deploys to the iPhone.
2. **Teleprompter Engine**: `prompter.html` + vendored KaTeX as resources, Markdown+LaTeX render, native↔JS scroll control, all reading controls, mirror flip. Usable as a standalone prompter.
3. **CameraKit + overlay**: live preview, front/back, focus/zoom, prompter overlaid, Record + Prompt-only modes, save recordings.
4. **Cinematic**: synthetic fallback first (segmentation + Core Image blur via `AVAssetWriter`), then real iOS 26 path behind availability, unified UI.
5. **SyncKit**: MultipeerConnectivity discovery/roles, mirror scroll+play-state, remote control, then adaptive live-preview streaming with graceful fallback.
6. **LANServer**: `Network`-framework HTTP server, web script editor with matching KaTeX preview, QR code, live write-back.
7. **Polish**: settings, empty states, error handling, permission flows, performance passes on camera+sync.

---

## 9. DEFINITION OF DONE

- `xtool dev build` succeeds with no warnings you introduced; runs on a physical iPhone and iPad.
- A user can: paste a script → style it (color/bold/italic/LaTeX) → read it scrolling over the camera → record with cinematic (real or synthetic) → OR run prompt-only → mirror + remote-control from a second device on the same Wi-Fi with no internet → edit scripts from a laptop browser on the LAN.
- Cinematic real/synthetic chosen automatically by capability and labeled honestly.
- No stubbed logic; every button works. `BUILD_NOTES.md` lists any xtool caveats and how each was handled.

---

## 10. HARD PARTS — HANDLE EXPLICITLY

- **xtool compatibility**: keep every dependency pure-Swift or system-framework; no asset catalogs; resources via `Bundle.module`; Info.plist + entitlements in `xtool.yml`. Any capability that won't build under xtool goes behind a protocol with a working default and a note.
- **Live video over Multipeer** is the biggest runtime risk: adaptive from the start; always keep the prompter-mirror alive even if video streaming degrades.
- **Synthetic bokeh at framerate**: blur in Metal/Core Image on a background queue; never stall capture.
- **Real Cinematic gating**: never call iOS 26 symbols without `#available` + capability check.
- **WebView scroll smoothness**: JS `requestAnimationFrame`; native side sends commands only.
- **Local-network permission**: both Multipeer and the LAN server trigger it — request, explain, handle denial.

Deliver the full **SwiftPM project in xtool layout** (`Package.swift`, `xtool.yml`, `Sources/…`, vendored web resources, `BUILD_NOTES.md`), organized by the module structure above, with brief comments on the non-obvious camera/sync/cinematic code.
