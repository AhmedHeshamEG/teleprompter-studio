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
            transportRow
        }
        .padding(Theme.spacingM)
        // The sliders panel is an *overlay* anchored above the transport row, not another row in
        // the stack. As a stack row it changed the stack's height, which pushed the whole
        // bottom-anchored chrome upward — so the button the user had just tapped moved out from
        // under their finger and the second tap (meant to close the panel) landed on the panel
        // instead. The row now never moves, so tapping the same spot toggles it shut.
        .overlay(alignment: .top) {
            if showingSliders {
                slidersPanel
                    .alignmentGuide(.top) { $0[.bottom] + Theme.spacingS }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var transportRow: some View {
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
    }

    private var slidersPanel: some View {
        VStack(spacing: Theme.spacingS) {
            LabeledSlider(
                label: "Speed",
                systemImage: "speedometer",
                value: $controller.speedPxPerSec,
                range: 10...400
            ) { "\(Int($0)) px/s" }

            LabeledSlider(
                label: "Font Size",
                systemImage: "textformat.size",
                value: $controller.fontSize,
                range: 18...120
            ) { "\(Int($0)) pt" }

            Picker("Guide", selection: Binding(
                get: { controller.guideMode },
                set: { controller.setGuide($0) }
            )) {
                Text("Line").tag(PrompterGuideMode.line)
                Text("Band").tag(PrompterGuideMode.band)
                Text("Off").tag(PrompterGuideMode.none)
            }
            .pickerStyle(.segmented)

            Button("Close") {
                withAnimation(Theme.quickSpring) { showingSliders = false }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, Theme.spacingXS)
        }
        .padding(Theme.spacingM)
        .frame(maxWidth: 460)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium).stroke(Theme.border, lineWidth: 1))
        .padding(.horizontal, Theme.spacingM)
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
