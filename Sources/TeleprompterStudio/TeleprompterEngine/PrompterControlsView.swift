import SwiftUI

/// Reusable prompter transport chrome: progress bar, play/pause, restart, 3-2-1 countdown, and
/// the toggle for the speed/font-size panel.
///
/// The panel itself is deliberately **not** rendered here — see `PrompterSlidersPanel`. The screen
/// that owns this view presents it as a system sheet, so it can never sit ambiguously on top of
/// (or underneath) the record button.
struct PrompterControlsView: View {
    @Bindable var controller: PrompterController
    @Binding var showingSliders: Bool

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            PrompterProgressBar(controller: controller)
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

            // No `withAnimation` — the sheet brings its own presentation animation.
            ChromeButton(systemImage: "slider.horizontal.3", isActive: showingSliders, size: Theme.minControlSizeCompact) {
                showingSliders.toggle()
            }
        }
    }
}

/// The progress bar reads `controller.progress`, which updates ~10× a second during playback. It's
/// its own view so those updates redraw a 6pt capsule and nothing else — kept inside
/// `PrompterControlsView`, every progress tick also rebuilt the transport buttons next to it, and a
/// button being rebuilt underneath a finger is a button that drops the tap.
private struct PrompterProgressBar: View {
    let controller: PrompterController

    var body: some View {
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

/// Speed / font-size / guide panel, shown in a short system sheet (`.presentationDetents`) that
/// only covers the bottom of the screen.
///
/// It's a sheet rather than a hand-rolled overlay because that's the platform answer to exactly
/// this problem: it can't overlap the record button (the sheet owns its own space and blocks the
/// content behind it), it comes with the standard grabber, swipe-to-dismiss, blurred material and
/// spring animation, and it needs no custom scrim, no tap-swallowing tricks, and no guessing about
/// which control a touch belonged to. The panel content itself is the same set of controls as
/// before — nothing about the look of the sliders has changed, only where they live.
struct PrompterSlidersPanel: View {
    @Bindable var controller: PrompterController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingL) {
            Text("Prompter")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

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

            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Label("Reading Guide", systemImage: "text.aligncenter")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                Picker("Reading Guide", selection: Binding(
                    get: { controller.guideMode },
                    set: { controller.setGuide($0) }
                )) {
                    Text("Line").tag(PrompterGuideMode.line)
                    Text("Band").tag(PrompterGuideMode.band)
                    Text("Off").tag(PrompterGuideMode.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacingL)
        .padding(.top, Theme.spacingL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadiusLarge)
        .presentationBackgroundInteraction(.disabled)
        .preferredColorScheme(.dark)
    }
}
