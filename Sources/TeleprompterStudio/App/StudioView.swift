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

    /// Landscape on iPhone: short screen, wide screen. Both the chrome layout and the prompter
    /// card's proportions key off this.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }
    /// Set once the first real layout pass has run, so opening Studio while already in landscape
    /// gets landscape-shaped defaults instead of portrait ones stretched sideways.
    @State private var didApplyInitialLayout = false

    /// The prompter text is the floating, hand-draggable element (not the record controls).
    /// Position is stored as a screen-fraction so it stays valid across rotation/resizing
    /// instead of an absolute point that could land off-screen.
    @State private var promptPositionFraction = CGPoint(x: 0.5, y: 0.42)
    @State private var promptDragStart: CGPoint?
    @State private var promptSize: CGSize = .zero
    /// Card width as a fraction of screen width; adjusted by the corner resize grip alongside
    /// `viewModel.overlayHeightFraction`, so the whole card is hand-sizable on the fly.
    @State private var promptWidthFraction: Double = 0.92
    @State private var resizeStart: CGSize?

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
                        onPinch: { viewModel.setZoom(viewModel.session.currentZoom * $0) }
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

                floatingPrompterOverlay(in: screen.size)

                VStack {
                    topBar
                    if let errorMessage = viewModel.errorMessage {
                        cameraErrorBanner(errorMessage)
                    }
                    Spacer()
                    StudioCinematicBadge(viewModel: viewModel)
                    bottomChrome
                }
            }
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
            StudioSettingsSheet(viewModel: viewModel)
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

    /// The scrolling script, as a floating card: drag the top handle to move it, the bottom-right
    /// grip to resize it, and the script itself to nudge the reading position by hand.
    private func floatingPrompterOverlay(in screenSize: CGSize) -> some View {
        VStack(spacing: 0) {
            promptDragHandle(screenSize: screenSize)

            // Hit-testing is intentionally ON: the prompter is a real scroll view now, so the
            // reader can nudge the script by hand mid-take. Tap-to-focus still works anywhere
            // outside the card, and the card can be dragged out of the way by its handle.
            NativePrompterView(document: viewModel.document, controller: viewModel.prompterController)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .frame(height: screenSize.height * viewModel.overlayHeightFraction)
                .overlay(alignment: .bottomTrailing) { resizeGrip(screenSize: screenSize) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .stroke(Theme.border, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .frame(width: screenSize.width * promptWidthFraction)
        .opacity(viewModel.overlayOpacity)
        .onGeometryChange(for: CGSize.self, of: \.size) { promptSize = $0 }
        .position(
            x: promptPositionFraction.x * screenSize.width,
            y: promptPositionFraction.y * screenSize.height
        )
        .animation(Theme.smoothSpring, value: screenSize.width) // re-clamp smoothly on rotation
        .onAppear { applyInitialLayout(for: screenSize) }
        .onChange(of: screenSize) { oldSize, newSize in
            reflowCard(from: oldSize, to: newSize)
        }
    }

    /// Rotation used to stretch the card: its width and height are stored as fractions of the
    /// screen, so a card that was a comfortable 92%-wide column in portrait became a 92%-wide,
    /// half-height *band* in landscape — text reflowed to enormous line lengths, the card covering
    /// the frame, nothing where you left it. This converts the card's actual point size through the
    /// rotation instead, so it stays the same physical size on screen and only gets clamped when
    /// the new screen genuinely can't fit it.
    private func reflowCard(from oldSize: CGSize, to newSize: CGSize) {
        guard oldSize.width > 0, oldSize.height > 0, newSize.width > 0, newSize.height > 0 else { return }
        let widthPoints = oldSize.width * promptWidthFraction
        let heightPoints = oldSize.height * viewModel.overlayHeightFraction
        promptWidthFraction = min(max(widthPoints / newSize.width, 0.35), 1.0)
        viewModel.overlayHeightFraction = min(max(heightPoints / newSize.height, 0.15), 0.92)
        promptPositionFraction = clampedFraction(promptPositionFraction, size: promptSize, screenSize: newSize)
    }

    /// Landscape-first defaults for a Studio opened while the phone is already sideways. A
    /// full-width card on a landscape screen is a 700pt-wide line of text, which is unreadable at
    /// prompter speed; a narrower column sitting higher up leaves the chrome its own space.
    private func applyInitialLayout(for screenSize: CGSize) {
        guard !didApplyInitialLayout, screenSize.width > 0, screenSize.height > 0 else { return }
        didApplyInitialLayout = true
        guard screenSize.width > screenSize.height else { return }
        promptWidthFraction = 0.6
        viewModel.overlayHeightFraction = 0.52
        promptPositionFraction = CGPoint(x: 0.5, y: 0.36)
    }

    private func promptDragHandle(screenSize: CGSize) -> some View {
        Capsule()
            .fill(Theme.textTertiary)
            .frame(width: 44, height: 5)
            .padding(.vertical, Theme.spacingS)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.001)) // keeps the whole handle row tappable, not just the capsule glyph
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        let start = promptDragStart ?? promptPositionFraction
                        if promptDragStart == nil { promptDragStart = start }
                        promptPositionFraction = clampedFraction(
                            CGPoint(
                                x: start.x + value.translation.width / max(screenSize.width, 1),
                                y: start.y + value.translation.height / max(screenSize.height, 1)
                            ),
                            size: promptSize,
                            screenSize: screenSize
                        )
                    }
                    .onEnded { _ in promptDragStart = nil }
            )
    }

    /// Bottom-right corner grip: drag to resize the card's width and height live. Sizes are kept
    /// as screen fractions (same as the position) so a card sized in portrait stays sane in
    /// landscape. Height writes straight into `viewModel.overlayHeightFraction`, the same value
    /// the Studio Settings "Height" slider drives, so the two controls stay in agreement.
    private func resizeGrip(screenSize: CGSize) -> some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 34, height: 34)
            .background(Color.black.opacity(0.55), in: Circle())
            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            .padding(Theme.spacingXS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStart ?? CGSize(
                            width: promptWidthFraction,
                            height: viewModel.overlayHeightFraction
                        )
                        if resizeStart == nil { resizeStart = start }
                        // Doubled because the card is center-anchored: dragging the corner by N
                        // points grows the card by N on that side and N on the opposite one.
                        let widthDelta = 2 * value.translation.width / max(screenSize.width, 1)
                        let heightDelta = 2 * value.translation.height / max(screenSize.height, 1)
                        promptWidthFraction = min(max(start.width + widthDelta, 0.35), 1.0)
                        viewModel.overlayHeightFraction = min(max(start.height + heightDelta, 0.15), 0.92)
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }

    /// Keeps the card's center far enough from every edge that its own bounds (half-extent,
    /// converted to fractions of the current screen size) never leave the visible screen.
    private func clampedFraction(_ point: CGPoint, size: CGSize, screenSize: CGSize) -> CGPoint {
        guard screenSize.width > 0, screenSize.height > 0 else { return point }
        let halfWidthFraction = (size.width / 2 + Theme.spacingS) / screenSize.width
        let halfHeightFraction = (size.height / 2 + Theme.spacingS) / screenSize.height
        return CGPoint(
            x: min(max(point.x, halfWidthFraction), 1 - halfWidthFraction),
            y: min(max(point.y, halfHeightFraction), 1 - halfHeightFraction)
        )
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
        HStack {
            ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }

            Picker("Mode", selection: $viewModel.runMode) {
                ForEach(StudioRunMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()

            StudioRecordingIndicator(coordinator: viewModel.recordingCoordinator)

            // Own view: it reads the coordinator's peer list, which changes independently of
            // everything else on this screen.
            StudioPeerButton(coordinator: appState.syncCoordinator) { showingPeerSheet = true }
            ChromeButton(systemImage: "slider.horizontal.3", size: Theme.minControlSizeCompact) {
                showingSettingsSheet = true
            }
        }
        .padding(Theme.spacingM)
    }

    /// Portrait stacks the prompter transport above the capture controls. Landscape puts them side
    /// by side: two stacked rows ate roughly a third of a landscape screen's height, pushing the
    /// script and the frame into what was left. Same controls, same sizes, laid out for the space
    /// that actually exists — which is what the system's own camera chrome does when it rotates.
    private var bottomChrome: some View {
        Group {
            if isCompactHeight {
                HStack(alignment: .center, spacing: Theme.spacingL) {
                    PrompterControlsView(
                        controller: viewModel.prompterController,
                        showingSliders: $showingPrompterSliders
                    )
                    .frame(maxWidth: .infinity)

                    captureControls
                }
                .padding(.horizontal, Theme.spacingM)
            } else {
                // Deliberate gap between the transport row and the record row — they were close
                // enough that a thumb aimed at one could catch the other.
                VStack(spacing: Theme.spacingM) {
                    PrompterControlsView(
                        controller: viewModel.prompterController,
                        showingSliders: $showingPrompterSliders
                    )
                    captureControls
                }
            }
        }
        .padding(.bottom, isCompactHeight ? Theme.spacingS : Theme.spacingM)
    }

    /// Each button that reads a *changing* value reads it inside its own small view. Read here, a
    /// single tap on record (or the torch, or Cinematic) invalidated this whole screen — including
    /// the camera preview's representable update pass and the prompter card — and a view rebuilt
    /// underneath a finger drops the press that was in flight. That is what "I have to tap it
    /// several times" is made of.
    private var captureControls: some View {
        HStack(spacing: Theme.spacingL) {
            if viewModel.runMode == .record {
                ChromeButton(systemImage: "arrow.triangle.2.circlepath.camera", size: Theme.minControlSizeCompact) {
                    viewModel.toggleFacing()
                }
                StudioCinematicButton(viewModel: viewModel)
            }

            StudioRecordButton(viewModel: viewModel)

            if viewModel.runMode == .record {
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
        switch viewModel.resolvedCinematicKind {
        case .real:
            Badge(text: "Cinematic", color: Theme.accent, filled: true)
        case .synthetic:
            Badge(text: "Simulated Cinematic", color: Theme.accent)
        case .none:
            EmptyView()
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
