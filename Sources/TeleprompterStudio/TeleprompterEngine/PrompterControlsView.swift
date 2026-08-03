import SwiftUI

/// Reusable prompter transport chrome: progress bar, play/pause, restart, 3-2-1 countdown, and
/// the toggle for the speed/font-size panel.
///
/// The panel is presented from the toggle button itself (see `PrompterSlidersPanel`) so that in
/// landscape it can appear as a popover anchored to the button rather than a card that swallows
/// the whole screen.
struct PrompterControlsView: View {
    @Bindable var controller: PrompterController
    @Binding var showingSliders: Bool

    /// Landscape on iPhone. Read here, in a real `View.body`, and handed to the panel explicitly —
    /// the size class seen *inside* presented content describes the presentation, not the screen
    /// that put it there, so deciding the adaptation from within the panel would be reading the
    /// wrong value.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

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

            // No `withAnimation` — the presentation brings its own animation.
            ChromeButton(systemImage: "slider.horizontal.3", isActive: showingSliders, size: Theme.minControlSizeCompact) {
                showingSliders.toggle()
            }
            // Anchored to the button, so in landscape it opens as a popover pointing at the
            // control that opened it. A sheet in landscape on iPhone is presented at full height
            // no matter what detents it asks for — which is exactly the "it covers everything"
            // problem. `presentationCompactAdaptation` inside the panel picks sheet (portrait) or
            // popover (landscape); this is the standard platform behaviour for a small options
            // panel hanging off a toolbar button.
            .popover(isPresented: $showingSliders) {
                PrompterSlidersPanel(controller: controller, prefersPopover: isCompactHeight)
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

/// Speed / font-size / guide panel.
///
/// Presented by the platform rather than hand-rolled as an overlay: it can't overlap the record
/// button, it comes with the standard grabber, dismissal, blurred material and spring animation,
/// and needs no custom scrim or tap-swallowing tricks. In portrait that's a short sheet pinned to
/// the bottom; in landscape (where an iPhone sheet is always full-height, covering the camera, the
/// script and every control) it's a popover anchored to the button that opened it.
struct PrompterSlidersPanel: View {
    let controller: PrompterController
    /// Set by the presenting view when the screen is landscape-on-iPhone.
    var prefersPopover: Bool = false

    /// The sliders write through `controller.setSpeed` / `setFontSize` rather than binding to the
    /// properties directly, because those setters are what persist the value for next launch.
    private var speed: Binding<Double> {
        Binding(get: { controller.speedPxPerSec }, set: { controller.setSpeed($0) })
    }

    private var fontSize: Binding<Double> {
        Binding(get: { controller.fontSize }, set: { controller.setFontSize($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingL) {
            Text("Prompter")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            LabeledSlider(
                label: "Speed",
                systemImage: "speedometer",
                value: speed,
                range: 10...400
            ) { "\(Int($0)) px/s" }

            LabeledSlider(
                label: "Font Size",
                systemImage: "textformat.size",
                value: fontSize,
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
        .padding(.bottom, prefersPopover ? Theme.spacingL : 0)
        // A popover sizes itself from its content, so it needs a width and height to aim for; a
        // sheet takes its height from the detent instead and spans the screen.
        .frame(width: prefersPopover ? 320 : nil)
        .frame(maxWidth: prefersPopover ? nil : .infinity, alignment: .leading)
        .presentationCompactAdaptation(prefersPopover ? .popover : .sheet)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(prefersPopover ? .hidden : .visible)
        .presentationBackground(.thinMaterial)
        .presentationCornerRadius(Theme.cornerRadiusLarge)
        .presentationBackgroundInteraction(.disabled)
        .preferredColorScheme(.dark)
    }
}
