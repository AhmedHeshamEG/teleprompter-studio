# Engineering notes

The things in this codebase that look odd until you know why.

## Building without a Mac

The app is a SwiftPM package with one library product, `TeleprompterStudio`, in the shape `xtool new` generates.
`Package.swift` lists `.macOS(.v14)` next to `.iOS(.v17)` only so SwiftPM and SourceKit can evaluate the manifest; the
app ships to iOS. The target builds in Swift 5 language mode.

`xtool.yml` points `infoPath` at `Info.plist`, which xtool merges over its generated defaults. There is no
entitlements file because nothing here needs one: camera, microphone, adding to Photos, local network and Bonjour
only need usage-description keys. `Info.plist` declares `_tpsync._tcp` / `_tpsync._udp` for MultipeerConnectivity and
`_tpweb._tcp` for the LAN server. `SyncCoordinator.serviceType` is `"tpsync"`, so rename both together or not at all.

xtool can't build packages with C targets or binary artifacts, which is why there are zero third-party Swift
dependencies. The CI workflow (`.github/workflows/build-ipa.yml`) runs on `macos-26` with Xcode 26 and produces the
unsigned `.ipa` on every push.

## Web assets

KaTeX 0.16.11 and marked.js 12.0.2 are vendored under `SharedWebResources/` and copied as whole directories, so the
relative font URLs inside `katex.min.css` still resolve inside `Bundle.module`. Nothing loads from a CDN. Only the
`.woff2` fonts are shipped; the CSS also lists `.woff` and `.ttf`, but WebKit on iOS 17 picks `.woff2` first, so the
other entries are never used.

The in-app editor and the browser editor render Markdown through the same marked.js, so a script looks the same in
both. Underline, colour and highlight have no Markdown syntax and are written as inline HTML (`<u>`, `<span
style="color:…">`, `<mark style="background-color:…">`), which marked passes through.

## The prompter

The prompter started as a `WKWebView` with JavaScript scrolling. It had no reliable signal that the page had loaded,
which showed up as a blank prompter at large font sizes, so it was rebuilt on UIKit: a TextKit `UITextView` driven by
a `CADisplayLink`. A plain `UILabel` can't do this job, because past the GPU's maximum texture height it draws nothing
at all.

The card's drag and resize gestures live in UIKit too. A drag moves one view's frame; in SwiftUI it re-rendered the
screen on every frame.

## Cinematic capture

`CameraKit/CinematicReal/CinematicVideoSupport.swift` calls Apple's Cinematic Video API directly
(`isCinematicVideoCaptureEnabled`, `simulatedAperture`, `setCinematicVideoTrackingFocus`, …), each call behind
`#available(iOS 26.0, *)` because the app still deploys to iOS 17. On an older OS the feature reports itself as
unsupported and nothing runs.

- Cinematic only exists on the back Dual Wide and the front TrueDepth cameras. The app normally opens the Triple
  camera for its telephoto, which has no Cinematic formats, so turning Cinematic on rebuilds the session around the
  right camera (`cinematicDevice(for:)`) and turning it off goes back.
- `metadataObjectTypes` has to be exactly the list Cinematic requires. Any other set throws while it's on.
- Cinematic records through the same `AVCaptureMovieFileOutput` as normal video. Apple writes the depth track.
- When the phone can't do it, the toggle switches itself back off and a banner says why.

## Zoom

`currentZoom` and `zoomPresets` use the stock Camera app's units, where 1× is the main wide lens. On a virtual
multi-lens camera a raw `videoZoomFactor` of 1.0 is the ultra-wide, so 1× is the first entry of
`virtualDeviceSwitchOverVideoZoomFactors`. It's re-applied after every device or format change, since those reset
zoom. Pinch and the lens button only work when Zoom Control is on in Studio Settings; it's off by default.

## Threads

`AVCameraSession` is deliberately not `@MainActor`. Apple wants `AVCaptureSession` configured off the main thread, so
every session and device change runs on a private serial `sessionQueue`, the class is `@unchecked Sendable`, and every
write to an observed property hops back to the main actor so SwiftUI only sees main-thread changes.

MultipeerConnectivity calls its delegates off the main thread, so `SyncCoordinator`'s delegate methods are
`nonisolated` and move into `Task { @MainActor in … }` before they touch state.

## Sync and preview streaming

`AVCaptureVideoDataOutput` allows one delegate. `CameraKit/VideoFrameMultiplexer` fans that callback out so more
than one consumer can read frames without blocking capture; today the consumer is the Companion preview.

`SyncKit/AdaptivePreviewStreamer` steps down a ladder (JPEG quality, then frame rate, then resolution, then off) based
on how long each frame takes to encode against its budget. If it hits the bottom, the Companion keeps the prompter
mirror and drops the video, which is better than letting frames pile up and stall the recording.

## The LAN server

`LANServer/` is HTTP/1.1 on `NWListener` and `NWConnection`, with a small parser in `HTTPTypes.swift`. It answers one
request per connection and sends `Connection: close`. It edits scripts on a home network; it isn't trying to be a web
server. The QR code comes from Core Image's `qrCodeGenerator`.

## Navigation

The root is a `TabView` (Scripts, Settings) rather than a `NavigationSplitView` sidebar. It adapts fine on iPad and
in Stage Manager, and it keeps Studio's full-screen camera free of split-view chrome.

## Making it yours

Change `bundleID` in `xtool.yml`, and replace `AppIcon.png` (a 1024×1024 PNG) if you're shipping your own build.
