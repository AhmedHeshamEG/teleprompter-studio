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
                .onChange(of: viewModel.resolution) { _, _ in viewModel.applyCaptureSettings() }
                .onChange(of: viewModel.fps) { _, _ in viewModel.applyCaptureSettings() }

                Section {
                    Toggle("Rule-of-Thirds Grid", isOn: $viewModel.showGrid)
                } header: {
                    Text("Framing")
                } footer: {
                    Text("Shows a 3×3 composition grid over the camera preview. It's never recorded into the video.")
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

                Section {
                    LabeledSlider(label: "Opacity", systemImage: "circle.lefthalf.filled", value: $viewModel.overlayOpacity, range: 0.3...1.0) {
                        "\(Int($0 * 100))%"
                    }
                    LabeledSlider(label: "Height", systemImage: "arrow.up.and.down", value: $viewModel.overlayHeightFraction, range: 0.25...0.9) {
                        "\(Int($0 * 100))%"
                    }
                } header: {
                    Text("Teleprompter Overlay")
                } footer: {
                    Text("Drag the handle above the script text to move the card, or its bottom-right grip to resize it. You can also nudge the script itself by hand mid-take.")
                }

                Section {
                    Picker("Rotation", selection: Binding(
                        get: { OrientationController.shared.lock },
                        set: { OrientationController.shared.lock = $0 }
                    )) {
                        ForEach(OrientationLock.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Rotation")
                } footer: {
                    Text("Auto follows however you're holding the phone. Portrait/Landscape locks the app to that orientation.")
                }

                if viewModel.cinematicMode == .cinematic {
                    Section(viewModel.resolvedCinematicKind == .real ? "Cinematic (Hardware)" : "Cinematic (Simulated)") {
                        if viewModel.resolvedCinematicKind == .real {
                            Picker("Focus Style", selection: $viewModel.realCinematic.focusMode) {
                                Text("Auto").tag(CinematicFocusMode.none)
                                Text("Strong Rack").tag(CinematicFocusMode.strong)
                                Text("Weak Rack").tag(CinematicFocusMode.weak)
                            }
                            // The system's own simulated aperture, in f-stops — the hardware
                            // equivalent of the synthetic path's blur amount.
                            LabeledSlider(
                                label: "Aperture",
                                systemImage: "camera.aperture",
                                value: Binding(
                                    get: { viewModel.cinematicAperture },
                                    set: { viewModel.setCinematicAperture($0) }
                                ),
                                range: 2...16
                            ) { String(format: "f/%.1f", $0) }
                        } else {
                            LabeledSlider(
                                label: "Aperture Blur",
                                systemImage: "camera.aperture",
                                value: Binding(
                                    get: { viewModel.recordingCoordinator.synthetic.blurRadius },
                                    set: { viewModel.recordingCoordinator.synthetic.setBlurRadius($0) }
                                ),
                                range: 0...60
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
