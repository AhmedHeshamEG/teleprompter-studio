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

    @State private var showingSettingsSheet = false
    @State private var showingPeerSheet = false

    /// The prompter text is the floating, hand-draggable element (not the record controls).
    /// Position is stored as a screen-fraction so it stays valid across rotation/resizing
    /// instead of an absolute point that could land off-screen.
    @State private var promptPositionFraction = CGPoint(x: 0.5, y: 0.42)
    @State private var promptDragStart: CGPoint?
    @State private var promptSize: CGSize = .zero

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

                    if viewModel.showGrid { GridOverlay().ignoresSafeArea() }
                    if let point = viewModel.focusPoint {
                        FocusReticle(point: point)
                    }
                }

                floatingPrompterOverlay(in: screen.size)

                VStack {
                    topBar
                    if let errorMessage = viewModel.errorMessage {
                        cameraErrorBanner(errorMessage)
                    }
                    Spacer()
                    if viewModel.resolvedCinematicKind == .synthetic {
                        Badge(text: "Simulated Cinematic", color: Theme.accent)
                    }
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
        .preferredColorScheme(.dark)
    }

    /// The scrolling script, as a floating card the user can drag anywhere on screen by its
    /// handle. Only the handle is hit-testable — `PrompterWebView` itself stays
    /// `allowsHitTesting(false)` so taps everywhere else (e.g. tap-to-focus on the camera
    /// underneath) keep working exactly as before.
    private func floatingPrompterOverlay(in screenSize: CGSize) -> some View {
        VStack(spacing: 0) {
            promptDragHandle(screenSize: screenSize)

            ZStack {
                // Guaranteed-visible plain-text rendering of the script, shown until the rich
                // WKWebView renderer confirms it actually loaded. If the WebView never becomes
                // ready for any reason, this stays up rather than leaving the screen blank.
                if !viewModel.prompterController.isPageReady {
                    nativePrompterFallback
                }

                PrompterWebView(document: viewModel.document, controller: viewModel.prompterController)
                    .opacity(viewModel.prompterController.isPageReady ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(height: screenSize.height * viewModel.overlayHeightFraction)
        }
        .frame(width: screenSize.width * 0.92)
        .opacity(viewModel.overlayOpacity)
        .onGeometryChange(for: CGSize.self, of: \.size) { promptSize = $0 }
        .position(
            x: promptPositionFraction.x * screenSize.width,
            y: promptPositionFraction.y * screenSize.height
        )
        .animation(Theme.smoothSpring, value: screenSize.width) // re-clamp smoothly on rotation
        .onChange(of: screenSize) { _, newSize in
            promptPositionFraction = clampedFraction(promptPositionFraction, size: promptSize, screenSize: newSize)
        }
    }

    /// Plain SwiftUI text, no WebKit involved at all — deliberately dumb (no markdown styling,
    /// no scrolling animation) so it has nothing else that could fail. Just needs to put the
    /// user's actual script on screen.
    private var nativePrompterFallback: some View {
        ScrollView(showsIndicators: false) {
            Text(viewModel.script.bodyMarkdown)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.spacingM)
        }
        .background(Color.black.opacity(0.6))
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

            RecordingIndicator(isRecording: viewModel.recordingCoordinator.isRecording, elapsed: viewModel.recordingCoordinator.elapsed)

            ChromeButton(systemImage: "person.2.fill", size: Theme.minControlSizeCompact) {
                showingPeerSheet = true
            }
            ChromeButton(systemImage: "slider.horizontal.3", size: Theme.minControlSizeCompact) {
                showingSettingsSheet = true
            }
        }
        .padding(Theme.spacingM)
    }

    private var bottomChrome: some View {
        VStack(spacing: Theme.spacingS) {
            PrompterControlsView(controller: viewModel.prompterController)

            HStack(spacing: Theme.spacingL) {
                if viewModel.runMode == .record {
                    ChromeButton(systemImage: "arrow.triangle.2.circlepath.camera", size: Theme.minControlSizeCompact) {
                        viewModel.toggleFacing()
                    }
                    ChromeButton(
                        systemImage: "sparkles",
                        isActive: viewModel.cinematicMode == .cinematic,
                        size: Theme.minControlSizeCompact
                    ) {
                        viewModel.toggleCinematic()
                    }
                }

                RecordButton(isRecording: viewModel.recordingCoordinator.isRecording) {
                    if viewModel.recordingCoordinator.isRecording {
                        viewModel.stopRecordingIfNeeded()
                    } else {
                        viewModel.startCountdownAndRecord()
                    }
                }

                if viewModel.runMode == .record {
                    ChromeButton(systemImage: "square.grid.3x3", isActive: viewModel.showGrid, size: Theme.minControlSizeCompact) {
                        viewModel.showGrid.toggle()
                    }
                    ChromeButton(systemImage: viewModel.session.torchOn ? "bolt.fill" : "bolt.slash", size: Theme.minControlSizeCompact) {
                        viewModel.session.setTorch(on: !viewModel.session.torchOn)
                    }
                }
            }
        }
        .padding(.bottom, Theme.spacingM)
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 30)
                    .fill(Theme.record)
                    .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    .animation(Theme.quickSpring, value: isRecording)
            }
        }
        .buttonStyle(.plain)
    }
}
