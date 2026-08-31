import SwiftUI

/// How the Director's camera is shown on the Companion.
enum CompanionMonitorMode: String, CaseIterable {
    /// Fills the screen behind the prompter — the Companion looks like the Director's screen.
    case full
    /// Small picture-in-picture in the corner, out of the reader's way.
    case pip
    /// Hidden: prompter only, on black.
    case off

    var next: CompanionMonitorMode {
        switch self {
        case .full: return .pip
        case .pip: return .off
        case .off: return .full
        }
    }

    var systemImage: String {
        switch self {
        case .full: return "rectangle.inset.filled"
        case .pip: return "rectangle.inset.bottomright.filled"
        case .off: return "rectangle.slash"
        }
    }

    var label: String {
        switch self {
        case .full: return "Full monitor"
        case .pip: return "Corner monitor"
        case .off: return "Monitor off"
        }
    }
}

/// Full-screen Companion experience: this device mirrors the Director's script + scroll position
/// live, shows the Director's camera as a live monitor, and can remote-control playback/recording.
///
/// It's deliberately built out of the same pieces as Studio — full-bleed camera behind, the same
/// draggable/resizable `FloatingPrompterCard` on top, the same chrome — so the second device reads
/// as the Director's screen rather than as a separate, smaller app. The camera was previously a
/// fixed 160pt thumbnail pinned to one corner with no way to change it.
struct CompanionView: View {
    let coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var controller = PrompterController()
    @State private var monitorMode: CompanionMonitorMode = .full
    @State private var overlayHeightFraction: Double = 0.55
    /// Measured height of this screen's own chrome, so the prompter card stays clear of it — the
    /// Companion is a mirror of the Director's layout and inherits the same landscape squeeze.
    @State private var chromeInsets = PrompterChromeInsets()
    /// Mirrors Studio's hide button: on the Companion this matters just as much, since it's often
    /// the device sitting under the lens.
    @State private var chromeVisible = true

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    /// How far the local scroll may drift from the Director's reported position before it's
    /// snapped back. The Companion scrolls under its own steam at the Director's speed and only
    /// corrects on real drift — snapping to every position report, four times a second, is what
    /// made the mirrored script stutter instead of read.
    private let driftTolerance = 0.015

    var body: some View {
        GeometryReader { screen in
            ZStack {
                Color.black.ignoresSafeArea()

                // Its own view on purpose: a new frame arrives ~10-18 times a second, and reading
                // it here would invalidate the whole Companion screen — prompter card included —
                // at that rate. Same mistake that made the Director's card drag stutter.
                CompanionMonitor(coordinator: coordinator, mode: monitorMode, screenSize: screen.size)

                FloatingPrompterCard(
                    document: coordinator.latestDocument ?? PrompterDocument(markdown: placeholderText),
                    controller: controller,
                    opacity: 0.92,
                    heightFraction: $overlayHeightFraction,
                    screenSize: screen.size,
                    chromeInsets: chromeInsets,
                    showsHandles: chromeVisible
                )

                // Same landscape reasoning as Studio: on a ~390pt-tall screen the controls take
                // the width, never the height, or there is nothing left for the script.
                if isCompactHeight {
                    HStack {
                        VStack(spacing: Theme.spacingM) {
                            if chromeVisible { topBarItems }
                        }
                        .padding(.leading, Theme.spacingS)
                        .onGeometryChange(for: CGFloat.self, of: \.size.width) { chromeInsets.leading = $0 + Theme.spacingS }

                        Spacer(minLength: 0)

                        VStack(spacing: Theme.spacingL) { remoteControlItems }
                            .disabled(coordinator.connectionState != .connected)
                            .opacity(coordinator.connectionState == .connected ? 1 : 0.4)
                            .padding(.trailing, Theme.spacingS)
                            .onGeometryChange(for: CGFloat.self, of: \.size.width) { chromeInsets.trailing = $0 + Theme.spacingS }
                    }
                } else {
                    VStack {
                        HStack { topBarItems }
                            .padding(Theme.spacingM)
                            // Faded *and* deaf: a control you can't see but can still press is
                            // worse than one that's simply gone.
                            .opacity(chromeVisible ? 1 : 0)
                            .allowsHitTesting(chromeVisible)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { chromeInsets.top = $0 }
                        Spacer()
                        HStack(spacing: Theme.spacingL) { remoteControlItems }
                            .disabled(coordinator.connectionState != .connected)
                            .opacity(coordinator.connectionState == .connected ? 1 : 0.4)
                            .padding(Theme.spacingL)
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { chromeInsets.bottom = $0 }
                    }
                }

                VStack {
                    HStack {
                        Spacer()
                        ChromeButton(
                            systemImage: chromeVisible
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right",
                            isActive: !chromeVisible,
                            size: Theme.minControlSizeCompact
                        ) {
                            chromeVisible.toggle()
                        }
                        .accessibilityLabel(chromeVisible ? "Hide controls" : "Show controls")
                    }
                    Spacer()
                }
                .padding(.trailing, Theme.spacingM)
                .padding(.top, isCompactHeight ? Theme.spacingS : Theme.spacingM)
            }
            .animation(Theme.quickSpring, value: chromeVisible)
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .peerInviteAlert(coordinator: coordinator)
        .onChange(of: coordinator.latestDocument) { _, newValue in
            if let newValue { controller.loadDocument(newValue) }
        }
        .onChange(of: coordinator.latestPlayback?.fraction) { _, _ in
            applyPlaybackState()
        }
        .onAppear {
            coordinator.setRole(.companion)
            // Entering Companion mode used to start neither the advertiser nor the browser, so a
            // device that hadn't already opened "Connect a Device" could never be found or find
            // anyone — the screen just sat on its placeholder forever.
            coordinator.startHosting()
            // `.onChange` only fires on *changes*, and the Director publishes the script the moment
            // a peer connects — which is usually before this screen exists. Without this, arriving
            // after the script had already been sent left the prompter on the placeholder.
            if let document = coordinator.latestDocument {
                controller.loadDocument(document)
            }
            applyPlaybackState()
        }
        .onDisappear {
            controller.pause()
        }
    }

    private var placeholderText: String {
        switch coordinator.connectionState {
        case .connected: return "Connected. Waiting for the Director's script…"
        case .connecting: return "Connecting to the Director…"
        case .notConnected: return "Looking for a Director on this Wi-Fi network…\n\nOn the other device: Settings → Connect a Device, then tap this device's name."
        }
    }

    /// Mirrors the Director's transport state, not just its position: same speed, same font size,
    /// same play/pause, with a position correction only when the two have genuinely drifted apart.
    /// Written straight to the properties rather than through `setSpeed`/`setFontSize`, because
    /// those persist the value as *this* reader's own preference — mirroring someone else's screen
    /// shouldn't overwrite the settings this device uses when it's the one being read from.
    private func applyPlaybackState() {
        guard let playback = coordinator.latestPlayback else { return }
        if abs(controller.speedPxPerSec - playback.speed) > 0.5 {
            controller.speedPxPerSec = playback.speed
        }
        if abs(controller.fontSize - playback.fontSize) > 0.5 {
            controller.fontSize = playback.fontSize
        }
        if abs(controller.progress - playback.fraction) > driftTolerance {
            controller.jumpToFraction(playback.fraction)
        }
        if playback.isPlaying != controller.isPlaying {
            playback.isPlaying ? controller.play() : controller.pause()
        }
    }

    @ViewBuilder
    private var topBarItems: some View {
        ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }
        if !isCompactHeight { Spacer() }
        Badge(
            text: coordinator.connectionState == .connected ? "Companion · Linked" : "Companion · Searching",
            color: coordinator.connectionState == .connected ? Theme.success : Theme.textSecondary,
            filled: coordinator.connectionState == .connected
        )
        if coordinator.remoteIsRecording {
            RecordingIndicator(isRecording: true, elapsed: coordinator.remoteElapsed)
        }
        if !isCompactHeight { Spacer() }
        // One button, three states: full monitor → corner monitor → off → full. Closing the
        // camera is never a one-way door.
        ChromeButton(systemImage: monitorMode.systemImage, size: Theme.minControlSizeCompact) {
            withAnimation(Theme.quickSpring) { monitorMode = monitorMode.next }
        }
        .accessibilityLabel(monitorMode.label)
        // Keeps this row clear of the floating hide/show button in the same corner.
        if !isCompactHeight { Color.clear.frame(width: 48, height: 1) }
    }

    @ViewBuilder
    private var remoteControlItems: some View {
        ChromeButton(systemImage: "gobackward") {
            coordinator.sendRemoteCommand(.jumpToTop)
        }
        ChromeButton(
            systemImage: (coordinator.latestPlayback?.isPlaying ?? false) ? "pause.fill" : "play.fill",
            isActive: true
        ) {
            coordinator.sendRemoteCommand(.togglePlayback)
        }
        ChromeButton(
            systemImage: coordinator.remoteIsRecording ? "stop.fill" : "record.circle",
            isDestructive: true
        ) {
            coordinator.sendRemoteCommand(coordinator.remoteIsRecording ? .stopRecording : .startRecording)
        }
    }
}

/// The Director's camera as the Companion sees it. Aspect-fit rather than fill: this is a monitor,
/// and cropping the frame would misrepresent the shot the Director is actually recording.
private struct CompanionMonitor: View {
    let coordinator: SyncCoordinator
    let mode: CompanionMonitorMode
    let screenSize: CGSize

    var body: some View {
        if mode != .off, coordinator.isPreviewStreamAvailable, let image = coordinator.latestPreviewImage {
        switch mode {
        case .full:
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: screenSize.width, height: screenSize.height)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        case .pip:
            VStack {
                HStack {
                    Spacer()
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: min(200, screenSize.width * 0.32))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall).stroke(Theme.border, lineWidth: 1))
                        .padding(.horizontal, Theme.spacingM)
                        .padding(.top, 64) // clear of the top chrome row
                }
                Spacer()
            }
            .allowsHitTesting(false)
        case .off:
            EmptyView()
        }
        } else if mode != .off, !coordinator.isPreviewStreamAvailable {
        VStack {
            Spacer()
            Badge(text: "Prompter mirror only", color: Theme.textSecondary)
                .padding(.bottom, 120)
        }
        }
    }
}
