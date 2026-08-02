import SwiftUI

/// Reusable prompter transport chrome: progress bar, play/pause, restart, 3-2-1 countdown,
/// speed + font-size sliders. Used standalone (prompt-only mode) and layered over the camera
/// preview in Studio.
struct PrompterControlsView: View {
    @Bindable var controller: PrompterController
    var onRequestExpandedSettings: (() -> Void)?

    @State private var showingSliders = false

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            progressBar

            HStack(spacing: Theme.spacingL) {
                ChromeButton(systemImage: "gobackward", size: Theme.minControlSizeCompact) {
                    controller.jumpToTop()
                }

                ChromeButton(systemImage: controller.isPlaying ? "pause.fill" : "play.fill", isActive: true) {
                    controller.toggle()
                }

                ChromeButton(systemImage: "timer", size: Theme.minControlSizeCompact) {
                    controller.startCountdown(seconds: 3)
                }

                ChromeButton(systemImage: "slider.horizontal.3", isActive: showingSliders, size: Theme.minControlSizeCompact) {
                    withAnimation(Theme.quickSpring) { showingSliders.toggle() }
                }
            }

            if showingSliders {
                VStack(spacing: Theme.spacingS) {
                    LabeledSlider(
                        label: "Speed",
                        systemImage: "speedometer",
                        value: $controller.speedPxPerSec,
                        range: 10...400
                    ) { "\(Int($0)) px/s" }
                    .onChange(of: controller.speedPxPerSec) { _, newValue in
                        controller.setSpeed(newValue)
                    }

                    LabeledSlider(
                        label: "Font Size",
                        systemImage: "textformat.size",
                        value: $controller.fontSize,
                        range: 18...120
                    ) { "\(Int($0)) pt" }
                    .onChange(of: controller.fontSize) { _, newValue in
                        controller.setFontSize(newValue)
                    }

                    Picker("Guide", selection: Binding(
                        get: { controller.guideMode },
                        set: { controller.setGuide($0) }
                    )) {
                        Text("Line").tag(PrompterGuideMode.line)
                        Text("Band").tag(PrompterGuideMode.band)
                        Text("Off").tag(PrompterGuideMode.none)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(Theme.spacingM)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(Theme.spacingM)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(Theme.accent)
                    .frame(width: max(4, proxy.size.width * controller.progress))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = max(0, min(1, value.location.x / max(1, proxy.size.width)))
                    controller.jumpToFraction(fraction)
                }
            )
        }
        .frame(height: 6)
    }
}
