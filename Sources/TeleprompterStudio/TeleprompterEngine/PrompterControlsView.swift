import SwiftUI

/// Reusable prompter transport chrome: progress bar, play/pause, restart, 3-2-1 countdown, and
/// the toggle for the speed/font-size panel.
///
/// The panel itself is deliberately **not** rendered here — see `PrompterSlidersPanel`. It's
/// presented by the screen that owns this view, on its own layer above every other control, so it
/// can never sit ambiguously on top of (or underneath) the record button.
struct PrompterControlsView: View {
    @Bindable var controller: PrompterController
    @Binding var showingSliders: Bool

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            progressBar
            transportRow
        }
        .padding(Theme.spacingM)
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

/// Speed / font-size / guide panel. Presented as its own modal layer (scrim + centered card)
/// rather than as chrome wedged in among the transport buttons: as an inline element it sat
/// directly over the record button's neighbourhood, so a tap aimed at a slider could land on
/// record instead. On its own layer above a tap-absorbing scrim, nothing underneath is reachable
/// while it's open, and tapping away closes it.
struct PrompterSlidersPanel: View {
    @Bindable var controller: PrompterController
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            HStack {
                Text("Prompter")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                ChromeButton(systemImage: "xmark", size: 32, action: onClose)
            }

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
        }
        .padding(Theme.spacingM)
        .frame(maxWidth: 460)
        .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        // Swallows every touch that lands on the card so nothing behind it reacts, including
        // drags that start on a slider and wander off it.
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
        .onTapGesture {}
    }
}
