import SwiftUI

/// Full-screen Companion experience: this device mirrors the Director's script + scroll
/// position live, shows the Director's camera as a live monitor, and can remote-control
/// playback/recording. All three roles the spec calls out, in one screen.
struct CompanionView: View {
    let coordinator: SyncCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var controller = PrompterController()
    @State private var showMonitor = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            PrompterWebView(
                document: coordinator.latestDocument ?? PrompterDocument(markdown: "_Waiting for Director…_"),
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
        .onChange(of: coordinator.latestDocument) { _, newValue in
            if let newValue { controller.loadDocument(newValue) }
        }
        .onChange(of: coordinator.latestPlayback?.fraction) { _, _ in
            guard let playback = coordinator.latestPlayback else { return }
            controller.jumpToFraction(playback.fraction)
        }
        .onAppear {
            coordinator.setRole(.companion)
        }
    }

    private var topBar: some View {
        HStack {
            ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }
            Spacer()
            Badge(text: "Companion", color: Theme.accent)
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
    }
}
