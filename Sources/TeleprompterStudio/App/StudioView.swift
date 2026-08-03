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

    /// Floating control panel position, as a fraction (0...1) of the screen so it stays valid
    /// across rotation/resizing instead of an absolute point that would land off-screen.
    @State private var panelPositionFraction = CGPoint(x: 0.5, y: 0.86)
    @State private var panelDragStart: CGPoint?
    @State private var panelSize: CGSize = .zero

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

                prompterOverlay

                VStack {
                    topBar
                    Spacer()
                }

                floatingControlPanel(in: screen.size)
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

    private var prompterOverlay: some View {
        GeometryReader { proxy in
            PrompterWebView(document: viewModel.document, controller: viewModel.prompterController)
                .opacity(viewModel.overlayOpacity)
                .frame(height: proxy.size.height * viewModel.overlayHeightFraction)
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height * (0.5 + viewModel.overlayVerticalOffset)
                )
        }
        .allowsHitTesting(false)
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

    /// The prompter/record controls as a self-contained panel the user can drag anywhere on
    /// screen with a finger, rather than a bar pinned to the bottom. Position is stored as a
    /// screen-fraction (`panelPositionFraction`) so it stays valid across device rotation, and
    /// dragging is clamped so the panel can never be dragged fully off-screen.
    private func floatingControlPanel(in screenSize: CGSize) -> some View {
        VStack(spacing: Theme.spacingS) {
            dragHandle
                .contentShape(Rectangle().inset(by: -12)) // generous hit target for the handle
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .local)
                        .onChanged { value in
                            let start = panelDragStart ?? panelPositionFraction
                            if panelDragStart == nil { panelDragStart = start }
                            panelPositionFraction = clampedFraction(
                                CGPoint(
                                    x: start.x + value.translation.width / max(screenSize.width, 1),
                                    y: start.y + value.translation.height / max(screenSize.height, 1)
                                ),
                                screenSize: screenSize
                            )
                        }
                        .onEnded { _ in panelDragStart = nil }
                )

            if viewModel.resolvedCinematicKind == .synthetic {
                Badge(text: "Simulated Cinematic", color: Theme.accent)
            }

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
            .padding(.bottom, Theme.spacingS)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge).stroke(Theme.border, lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .onGeometryChange(for: CGSize.self, of: \.size) { panelSize = $0 }
        .position(
            x: panelPositionFraction.x * screenSize.width,
            y: panelPositionFraction.y * screenSize.height
        )
        .animation(Theme.smoothSpring, value: screenSize.width) // re-clamp smoothly on rotation
        .onChange(of: screenSize) { _, newSize in
            panelPositionFraction = clampedFraction(panelPositionFraction, screenSize: newSize)
        }
    }

    /// Keeps the panel's center far enough from every edge that its own bounds (half-extent,
    /// converted to fractions of the current screen size) never leave the visible screen.
    private func clampedFraction(_ point: CGPoint, screenSize: CGSize) -> CGPoint {
        guard screenSize.width > 0, screenSize.height > 0 else { return point }
        let halfWidthFraction = (panelSize.width / 2 + Theme.spacingS) / screenSize.width
        let halfHeightFraction = (panelSize.height / 2 + Theme.spacingS) / screenSize.height
        return CGPoint(
            x: min(max(point.x, halfWidthFraction), 1 - halfWidthFraction),
            y: min(max(point.y, halfHeightFraction), 1 - halfHeightFraction)
        )
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Theme.textTertiary)
            .frame(width: 36, height: 5)
            .padding(.top, Theme.spacingS)
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
