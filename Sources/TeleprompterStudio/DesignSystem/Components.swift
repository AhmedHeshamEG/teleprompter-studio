import SwiftUI

/// A large, thumb-reachable circular icon button used throughout camera and prompter chrome.
struct ChromeButton: View {
    let systemImage: String
    var isActive: Bool = false
    var isDestructive: Bool = false
    var size: CGFloat = Theme.minControlSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .chromeGlass(in: Circle(), tint: tintColor)
                // The touch target is at least 48pt and the hit shape is declared on the *label*,
                // inside the Button. Declaring it outside (as this did) doesn't widen what the
                // button actually accepts, so the compact 44pt variants had genuinely small,
                // easy-to-miss targets — which reads as "I have to tap it several times".
                .frame(width: max(size, 48), height: max(size, 48))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Theme.quickSpring, value: isActive)
    }

    private var foregroundColor: Color {
        if isDestructive { return .white }
        return isActive ? .black : Theme.textPrimary
    }

    /// Plain glass at rest; tinted when switched on, like the stock Camera app's controls.
    private var tintColor: Color? {
        if isDestructive { return Theme.record }
        return isActive ? Theme.accent : nil
    }
}

/// The record button, shaped like the stock Camera app's: a white ring around a red dot that becomes a
/// rounded square while recording. Shared by Studio (video) and Voice.
struct RecordButton: View {
    let isRecording: Bool
    /// Countdown is running: the button pulses so the tap clearly registered, and tapping again
    /// calls the take off instead of doing nothing for three seconds.
    var isArmed: Bool = false
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(isArmed ? Theme.accent : Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 30)
                    .fill(Theme.record)
                    .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    .opacity(isArmed && pulse ? 0.35 : 1)
                    .animation(Theme.quickSpring, value: isRecording)
            }
            // The 76pt ring is the visual; this is the touch target, so the edges of the button
            // aren't dead zones.
            .frame(width: 88, height: 88)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onChange(of: isArmed) { _, armed in
            if armed {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
    }
}

/// Pill-shaped record indicator with a pulsing dot, used in camera chrome and recording lists.
struct RecordingIndicator: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    @State private var pulse = false

    var body: some View {
        if isRecording {
            // The stock Camera app's take timer: white timecode on a red pill.
            HStack(spacing: 6) {
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
                Text(elapsed.asTimecode)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.record, in: Capsule())
            .onAppear { pulse = true }
        }
    }
}

/// A labeled slider row used for speed / font-size / blur controls.
struct LabeledSlider: View {
    let label: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            HStack {
                Label(label, systemImage: systemImage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(format(value))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: $value, in: range)
                .tint(Theme.accent)
        }
    }
}

/// Standard empty-state view for lists with no content yet.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.spacingL)
                        .padding(.vertical, Theme.spacingS)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .padding(.top, Theme.spacingS)
            }
        }
        .padding(Theme.spacingXL)
        .frame(maxWidth: 340)
    }
}

/// A small rounded badge, used for "SIMULATED" cinematic labels, role tags, connection status, etc.
struct Badge: View {
    let text: String
    var color: Color = Theme.accent
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .padding(.horizontal, Theme.spacingS)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? .black : color)
            .background(filled ? color : Color.black.opacity(0.35), in: Capsule())
    }
}

extension TimeInterval {
    var asTimecode: String {
        let total = Int(self.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
