import SwiftUI
import SwiftData
import UIKit

/// The camera + teleprompter "Studio" screen: live camera preview (or a plain dark background
/// in Prompt-Only mode) with the scrolling script overlaid, record controls, and cinematic /
/// sync entry points. This is where "Go Live" from the editor lands.
struct StudioView: View {
    @State private var viewModel: CameraStudioViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showingSettingsSheet = false
    @State private var showingPeerSheet = false
    /// Owned here so the panel survives chrome rebuilds; presented from the button itself inside
    /// `PrompterControlsView` (sheet in portrait, popover in landscape).
    @State private var showingPrompterSliders = false

    /// How much room the top bar and the bottom controls actually take, measured from the chrome
    /// itself rather than guessed. Handed to `FloatingPrompterCard`, which confines the card to
    /// what's left — otherwise the card can be dragged (or grow) underneath controls that are drawn
    /// over it and eat the touch, which is exactly what happens in landscape, where the whole
    /// screen is barely 400pt tall.
    @State private var chromeInsets = PrompterChromeInsets()

    /// Everything except the script, the transport, the timer and the record button can be swept
    /// off the screen with one button. On a 390pt-tall landscape screen that is the difference
    /// between a prompter and a two-word slot, and it's also the only reliable way to see the
    /// frame you're actually recording.
    @State private var chromeVisible = true
    /// Bumped by Studio Settings' "Reset Card" to put the prompter card back where it started.
    @State private var resetCardToken = 0

    /// Landscape on iPhone: short screen, wide screen. Both the chrome layout and the prompter
    /// card's proportions key off this.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    init(script: Script) {
        _viewModel = State(initialValue: CameraStudioViewModel(script: script))
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                Color.black.ignoresSafeArea()

                if viewModel.runMode == .record {
                    CameraPreviewView(
                        cameraSession: viewModel.session,
                        onTap: { viewModel.focus(at: $0) },
                        onPinch: { viewModel.setZoom(viewModel.session.currentZoom * $0) },
                        subjectRelay: viewModel.cinematicSubjectRelay
                    )
                    .ignoresSafeArea()

                    // Live cinematic composite, drawn over the plain preview while the effect is
                    // on. Before this, Cinematic changed nothing you could see until you played
                    // back the file. Never takes touches, so focus/zoom still work underneath.
                    if viewModel.resolvedCinematicKind == .synthetic {
                        CinematicPreviewView(sink: viewModel.cinematicPreview)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    if viewModel.showGrid { GridOverlay().ignoresSafeArea() }
                    // In its own view: tapping to focus wrote `focusPoint`, and reading that here
                    // rebuilt the entire Studio screen — camera preview, prompter card and all —
                    // on every tap, for a reticle that occupies 72 points.
                    StudioFocusReticle(viewModel: viewModel)
                }

                FloatingPrompterCard(
                    document: viewModel.document,
                    controller: viewModel.prompterController,
                    opacity: viewModel.overlayOpacity,
                    heightFraction: $viewModel.overlayHeightFraction,
                    screenSize: screen.size,
                    chromeInsets: chromeInsets,
                    showsHandles: chromeVisible,
                    resetToken: resetCardToken
                )

                if isCompactHeight {
                    landscapeChrome
                } else {
                    portraitChrome
                }

                chromeToggle
            }
            .animation(Theme.quickSpring, value: chromeVisible)
        }
        .statusBarHidden()
        .task {
            viewModel.attach(syncCoordinator: appState.syncCoordinator, modelContext: modelContext)
            appState.isStudioActive = true
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
            appState.isStudioActive = false
        }
        .alert("Camera Access Needed", isPresented: $viewModel.isPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable camera and microphone access in Settings to use Studio.")
        }
        .sheet(isPresented: $showingSettingsSheet) {
            StudioSettingsSheet(viewModel: viewModel) { resetCardToken += 1 }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingPeerSheet) {
            PeerDiscoveryView(coordinator: appState.syncCoordinator)
        }
        // Studio covers the whole screen, so it has to be able to present an incoming connection
        // request itself — otherwise a Companion can never be accepted mid-session.
        .peerInviteAlert(coordinator: appState.syncCoordinator)
        .preferredColorScheme(.dark)
    }

    /// Portrait: the familiar stacked layout — bar across the top, transport and capture controls
    /// across the bottom. There is height to spare here, so nothing has to move.
    private var portraitChrome: some View {
        VStack {
            VStack(spacing: 0) {
                if chromeVisible {
                    topBar
                } else {
                    // The one thing from the top bar that stays: how long this take has been
                    // running. Hiding the controls shouldn't hide the clock.
                    HStack {
                        Spacer()
                        StudioRecordingIndicator(coordinator: viewModel.recordingCoordinator)
                        Spacer()
                        // Room for the floating hide/show button in the corner.
                        Color.clear.frame(width: 48, height: 44)
                    }
                    .padding(.horizontal, Theme.spacingM)
                }
                if let errorMessage = viewModel.errorMessage {
                    cameraErrorBanner(errorMessage)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                chromeInsets.top = height
            }

            Spacer()

            VStack(spacing: Theme.spacingS) {
                if chromeVisible { StudioCinematicBadge(viewModel: viewModel) }
                bottomChrome
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                chromeInsets.bottom = height
            }
        }
    }

    /// Landscape: the controls move to **side rails**, and the only thing left crossing the screen
    /// horizontally is a 44pt transport row.
    ///
    /// The previous layout kept the portrait bands — a top bar and a two-or-one-row control block
    /// — which together took roughly 270 of a landscape iPhone's ~390 points of height. Whatever
    /// was left is what the script had to fit in, which is why it came out as one or two words.
    /// Height is the scarce dimension in landscape and width is the plentiful one, so the chrome
    /// now spends width instead: exactly what the system camera does when it rotates.
    private var landscapeChrome: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: Theme.spacingM) {
                    if chromeVisible {
                        modePicker
                        StudioCinematicBadge(viewModel: viewModel)
                    }
                    // Always on, hidden chrome or not — see the portrait branch.
                    StudioRecordingIndicator(coordinator: viewModel.recordingCoordinator)
                }
                if let errorMessage = viewModel.errorMessage {
                    cameraErrorBanner(errorMessage)
                }
            }
            .padding(.top, Theme.spacingS)
            // Measured on the content itself: read after `.frame(maxHeight: .infinity)` this
            // reports the whole screen's height, and the card would be handed a top inset that
            // leaves it nowhere at all to sit.
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { chromeInsets.top = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 0) {
                VStack(spacing: Theme.spacingM) {
                    if chromeVisible {
                        ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }
                        rotationButton
                        StudioPeerButton(coordinator: appState.syncCoordinator) { showingPeerSheet = true }
                        ChromeButton(systemImage: "slider.horizontal.3", size: Theme.minControlSizeCompact) {
                            showingSettingsSheet = true
                        }
                    }
                }
                .padding(.leading, Theme.spacingS)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { chromeInsets.leading = $0 + Theme.spacingS }

                Spacer(minLength: 0)

                VStack(spacing: Theme.spacingM) {
                    captureControls
                }
                .padding(.trailing, Theme.spacingS)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { chromeInsets.trailing = $0 + Theme.spacingS }
            }

            PrompterControlsView(
                controller: viewModel.prompterController,
                showingSliders: $showingPrompterSliders
            )
            // Clear of both rails, so the progress bar can be dragged end to end.
            .padding(.horizontal, Theme.spacingXL * 2)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { chromeInsets.bottom = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// One button that sweeps the chrome off the screen and brings it back — the cheap, effective
    /// version of "get out of my way" the whole floating-prompter problem was really asking for.
    /// Amber while the chrome is hidden, so the state is legible at a glance mid-take.
    private var chromeToggle: some View {
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

    private var modePicker: some View {
        Picker("Mode", selection: $viewModel.runMode) {
            ForEach(StudioRunMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
    }

    /// Auto → Portrait → Landscape, on screen instead of three taps deep in the settings sheet.
    /// Rotation is a thing you decide *while* mounting the phone, which is the one moment you
    /// can't be opening sheets.
    private var rotationButton: some View {
        StudioRotationButton()
    }

    /// Camera-side failures used to fail silently (see `CameraStudioViewModel.start()`), which
    /// made real problems indistinguishable from "it's just not working" — this makes them
    /// visible instead of swallowed. The prompter text no longer depends on the camera at all,
    /// so this only ever affects the camera preview/recording, never the script.
    private func cameraErrorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.black)
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, Theme.spacingS)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
            .padding(.horizontal, Theme.spacingM)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.errorMessage = nil }
    }

    private var topBar: some View {
        VStack(spacing: Theme.spacingS) {
            HStack {
                ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }

                Spacer()

                StudioRecordingIndicator(coordinator: viewModel.recordingCoordinator)

                rotationButton

                // Own view: it reads the coordinator's peer list, which changes independently of
                // everything else on this screen.
                StudioPeerButton(coordinator: appState.syncCoordinator) { showingPeerSheet = true }
                ChromeButton(systemImage: "slider.horizontal.3", size: Theme.minControlSizeCompact) {
                    showingSettingsSheet = true
                }
                // The hide/show button sits in this corner as a floating overlay, so the row keeps
                // its place clear rather than shuffling sideways when the chrome comes back.
                Color.clear.frame(width: 48, height: 1)
            }
            modePicker
        }
        .padding(Theme.spacingM)
    }

    /// The portrait bottom block: prompter transport above the capture controls. (Landscape has no
    /// bottom block — see `landscapeChrome`.)
    private var bottomChrome: some View {
        // Deliberate gap between the transport row and the record row — they were close enough
        // that a thumb aimed at one could catch the other.
        VStack(spacing: Theme.spacingM) {
            PrompterControlsView(
                controller: viewModel.prompterController,
                showingSliders: $showingPrompterSliders
            )
            captureControls
        }
        .padding(.bottom, Theme.spacingM)
    }

    /// Each button that reads a *changing* value reads it inside its own small view. Read here, a
    /// single tap on record (or the torch, or Cinematic) invalidated this whole screen — including
    /// the camera preview's representable update pass and the prompter card — and a view rebuilt
    /// underneath a finger drops the press that was in flight. That is what "I have to tap it
    /// several times" is made of.
    private var captureControls: some View {
        // A row across the bottom in portrait, a column down the right-hand rail in landscape —
        // same controls, same sizes, laid out for the space that actually exists.
        AxisStack(isVertical: isCompactHeight, spacing: Theme.spacingL) {
            if viewModel.runMode == .record, chromeVisible {
                ChromeButton(systemImage: "arrow.triangle.2.circlepath.camera", size: Theme.minControlSizeCompact) {
                    viewModel.toggleFacing()
                }
                StudioCinematicButton(viewModel: viewModel)
            }

            // Never hidden: whatever else goes away, the take has to be startable and stoppable.
            StudioRecordButton(viewModel: viewModel)

            if viewModel.runMode == .record, chromeVisible {
                // The framing grid lives in Studio Settings now (and is on by default) — it's
                // a set-once framing preference, not something worth a permanent slot in the
                // thumb-reachable chrome next to the record button.
                StudioTorchButton(session: viewModel.session)
            }
        }
        .fixedSize()
    }
}

private struct StudioFocusReticle: View {
    let viewModel: CameraStudioViewModel

    var body: some View {
        if let point = viewModel.focusPoint {
            FocusReticle(point: point)
        }
    }
}

/// "Cinematic" when Apple's hardware path is running, "Simulated Cinematic" when the effect is
/// being produced in software — the distinction the user is entitled to see.
private struct StudioCinematicBadge: View {
    let viewModel: CameraStudioViewModel

    var body: some View {
        VStack(spacing: Theme.spacingXS) {
            // A camera that can't do what Settings says it's doing is worth one line on screen —
            // finding out from the file afterwards is finding out too late.
            if let note = viewModel.captureFallbackNote {
                Badge(text: note, color: Theme.warning)
            }
            switch viewModel.resolvedCinematicKind {
            case .real:
                Badge(text: "Cinematic", color: Theme.accent, filled: true)
                // The system's own scene assessment, the same "more light" warning the stock
                // Camera app shows. Cinematic degrades badly in low light and says so; passing
                // that on is more useful than letting the take look mysteriously mushy.
                if let warning = viewModel.session.cinematicSceneWarning {
                    Badge(text: warning, color: Theme.warning)
                }
            case .synthetic:
                Badge(text: "Simulated Cinematic", color: Theme.accent)
            case .none:
                EmptyView()
            }
        }
    }
}

private struct StudioCinematicButton: View {
    let viewModel: CameraStudioViewModel

    var body: some View {
        ChromeButton(
            systemImage: "sparkles",
            isActive: viewModel.cinematicMode == .cinematic,
            size: Theme.minControlSizeCompact
        ) {
            viewModel.toggleCinematic()
        }
    }
}

private struct StudioRecordButton: View {
    let viewModel: CameraStudioViewModel

    var body: some View {
        RecordButton(
            isRecording: viewModel.recordingCoordinator.isRecording,
            isArmed: viewModel.isArmed
        ) {
            viewModel.toggleRecording()
        }
    }
}

/// Opens "Connect a Device", and shows at a glance whether a Companion is actually linked — the
/// Director side previously gave no on-screen sign that a second device was (or wasn't) receiving
/// anything, which made a broken link indistinguishable from a working one.
private struct StudioPeerButton: View {
    let coordinator: SyncCoordinator
    let action: () -> Void

    var body: some View {
        let isLinked = coordinator.hasConnectedPeers
        ChromeButton(
            systemImage: isLinked ? "person.2.fill" : "person.2",
            isActive: isLinked,
            size: Theme.minControlSizeCompact,
            action: action
        )
    }
}

private struct StudioTorchButton: View {
    let session: AVCameraSession

    var body: some View {
        ChromeButton(systemImage: session.torchOn ? "bolt.fill" : "bolt.slash", size: Theme.minControlSizeCompact) {
            session.setTorch(on: !session.torchOn)
        }
    }
}

/// Wraps `RecordingIndicator` so the ticking `elapsed` value is read **inside this small view's
/// body**, not inside `StudioView.body`.
///
/// Read at the `StudioView` level, every timer tick invalidated the entire Studio screen: camera
/// chrome, the floating prompter card, the prompter's `UIViewRepresentable` update pass, the lot —
/// several times a second, for a label that changes once a second. That constant re-render is a
/// large part of why the app felt heavy and why taps on nearby buttons got dropped (SwiftUI
/// rebuilding a view mid-gesture loses the in-flight press).
private struct StudioRecordingIndicator: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        RecordingIndicator(isRecording: coordinator.isRecording, elapsed: coordinator.elapsed)
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    /// Countdown is running: the button pulses so the tap clearly registered, and tapping again
    /// calls the take off instead of doing nothing for three seconds.
    var isArmed: Bool = false
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(isArmed ? Theme.accent : Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 30)
                    .fill(Theme.record)
                    .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    .opacity(isArmed && pulse ? 0.35 : 1)
                    .animation(Theme.quickSpring, value: isRecording)
            }
            // The 76pt ring is the visual; this is the touch target, so the edges of the button
            // aren't dead zones.
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onChange(of: isArmed) { _, armed in
            if armed {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
    }
}

/// Lays its content out in a row or a column from one flag, so the capture controls can be a
/// bottom row in portrait and a right-hand rail in landscape without being written twice.
private struct AxisStack<Content: View>: View {
    let isVertical: Bool
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if isVertical {
            VStack(spacing: spacing) { content }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// Auto → Portrait → Landscape, one tap at a time.
///
/// Its own view because it reads `OrientationController.shared`, which changes independently of
/// everything else on the Studio screen — read in `StudioView.body` it would invalidate the camera
/// preview and the prompter card every time the phone was turned.
private struct StudioRotationButton: View {
    var body: some View {
        let lock = OrientationController.shared.lock
        ChromeButton(
            systemImage: lock.systemImage,
            isActive: lock != .auto,
            size: Theme.minControlSizeCompact
        ) {
            OrientationController.shared.lock = lock.next
        }
        .accessibilityLabel("Rotation: \(lock.rawValue)")
    }
}
