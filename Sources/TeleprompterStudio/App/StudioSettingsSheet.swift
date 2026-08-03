import AVFoundation
import SwiftUI

struct StudioSettingsSheet: View {
    @Bindable var viewModel: CameraStudioViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Picker("Resolution", selection: $viewModel.resolution) {
                        ForEach(CaptureResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame Rate", selection: $viewModel.fps) {
                        Text("24 fps").tag(24.0)
                        Text("30 fps").tag(30.0)
                        Text("60 fps").tag(60.0)
                    }
                }

                Section {
                    Picker("Microphone", selection: Binding(
                        get: { viewModel.session.selectedAudioDeviceID },
                        set: { newID in
                            let device = AVCameraSession.availableAudioDevices().first { $0.uniqueID == newID }
                            viewModel.setAudioDevice(device)
                        }
                    )) {
                        ForEach(AVCameraSession.availableAudioDevices(), id: \.uniqueID) { device in
                            Text(device.localizedName).tag(Optional(device.uniqueID))
                        }
                    }
                } footer: {
                    Text("Pick which connected microphone to record audio with — built-in, a wired/Bluetooth headset, or an external USB/Lightning mic.")
                }

                Section("Teleprompter Overlay") {
                    LabeledSlider(label: "Opacity", systemImage: "circle.lefthalf.filled", value: $viewModel.overlayOpacity, range: 0.3...1.0) {
                        "\(Int($0 * 100))%"
                    }
                    LabeledSlider(label: "Height", systemImage: "arrow.up.and.down", value: $viewModel.overlayHeightFraction, range: 0.25...0.9) {
                        "\(Int($0 * 100))%"
                    }
                    LabeledSlider(label: "Vertical Position", systemImage: "arrow.up.arrow.down", value: $viewModel.overlayVerticalOffset, range: -0.35...0.35) {
                        $0 < 0 ? "Near Lens" : ($0 > 0 ? "Lower" : "Center")
                    }
                }

                if viewModel.cinematicMode == .cinematic {
                    Section(viewModel.resolvedCinematicKind == .real ? "Cinematic (Hardware)" : "Cinematic (Simulated)") {
                        if viewModel.resolvedCinematicKind == .real {
                            Picker("Focus Style", selection: $viewModel.realCinematic.focusMode) {
                                Text("Auto").tag(CinematicFocusMode.none)
                                Text("Strong Rack").tag(CinematicFocusMode.strong)
                                Text("Weak Rack").tag(CinematicFocusMode.weak)
                            }
                        } else {
                            LabeledSlider(
                                label: "Aperture Blur",
                                systemImage: "camera.aperture",
                                value: Binding(
                                    get: { viewModel.recordingCoordinator.synthetic.blurRadius },
                                    set: { viewModel.recordingCoordinator.synthetic.setBlurRadius($0) }
                                ),
                                range: 0...40
                            )
                        }
                    }
                }

                Section("Mirror (Beam-Splitter Rig)") {
                    Toggle("Flip Horizontal", isOn: Binding(
                        get: { viewModel.script.style?.mirrorHorizontal ?? false },
                        set: { newValue in
                            viewModel.script.style?.mirrorHorizontal = newValue
                            viewModel.prompterController.setMirror(horizontal: newValue, vertical: viewModel.script.style?.mirrorVertical ?? false)
                        }
                    ))
                    Toggle("Flip Vertical", isOn: Binding(
                        get: { viewModel.script.style?.mirrorVertical ?? false },
                        set: { newValue in
                            viewModel.script.style?.mirrorVertical = newValue
                            viewModel.prompterController.setMirror(horizontal: viewModel.script.style?.mirrorHorizontal ?? false, vertical: newValue)
                        }
                    ))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Studio Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
