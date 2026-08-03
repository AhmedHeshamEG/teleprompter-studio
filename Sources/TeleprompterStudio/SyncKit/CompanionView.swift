import SwiftUI

/// Full-screen Companion experience: this device mirrors the Director's script + scroll
/// position live, shows the Director's camera as a live monitor, and can remote-control
/// playback/recording. All three roles the spec calls out, in one screen.
struct CompanionView: View {
    let coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var controller = PrompterController()
    @State private var showMonitor = true

    /// How far the local scroll may drift from the Director's reported position before it's
    /// snapped back. The Companion scrolls under its own steam at the Director's speed and only
    /// corrects on real drift — snapping to every position report, four times a second, is what
    /// made the mirrored script stutter instead of read.
    private let driftTolerance = 0.015

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            NativePrompterView(
                document: coordinator.latestDocument ?? PrompterDocument(markdown: placeholderText),
                controller: controller,
                isInteractivePreview: false
            )
            .ignoresSafeArea()

            if showMonitor, coordinator.isPreviewStreamAvailable, let image = coordinator.latestPreviewImage {
                VStack {
                    HStack {
                        Spacer()
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 160)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall).stroke(Theme.border, lineWidth: 1))
                            .padding(Theme.spacingM)
                    }
                    Spacer()
                }
            } else if !coordinator.isPreviewStreamAvailable {
                VStack {
                    HStack {
                        Spacer()
                        Badge(text: "Prompter mirror only", color: Theme.textSecondary)
                            .padding(Theme.spacingM)
                    }
                    Spacer()
                }
            }

            VStack {
                topBar
                Spacer()
                remoteControls
            }
        }
        .statusBarHidden()
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

    private var topBar: some View {
        HStack {
            ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }
            Spacer()
            Badge(
                text: coordinator.connectionState == .connected ? "Companion · Linked" : "Companion · Searching",
                color: coordinator.connectionState == .connected ? Theme.success : Theme.textSecondary,
                filled: coordinator.connectionState == .connected
            )
            if coordinator.remoteIsRecording {
                RecordingIndicator(isRecording: true, elapsed: coordinator.remoteElapsed)
            }
            Spacer()
            ChromeButton(systemImage: showMonitor ? "eye" : "eye.slash", size: Theme.minControlSizeCompact) {
                showMonitor.toggle()
            }
        }
        .padding(Theme.spacingM)
    }

    private var remoteControls: some View {
        HStack(spacing: Theme.spacingL) {
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
        .padding(Theme.spacingL)
        // Remote control is meaningless with nobody on the other end, and a dead-looking button you
        // can still press reads as a bug.
        .disabled(coordinator.connectionState != .connected)
        .opacity(coordinator.connectionState == .connected ? 1 : 0.4)
    }
}
