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

    init(script: Script) {
        _viewModel = State(initialValue: CameraStudioViewModel(script: script))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.runMode == .record {
                CameraPreviewView(
                    session: viewModel.session.captureSession,
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
                if viewModel.resolvedCinematicKind == .synthetic {
                    Badge(text: "Simulated Cinematic", color: Theme.accent)
                }
                bottomChrome
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
