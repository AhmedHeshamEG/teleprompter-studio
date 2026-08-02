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
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(backgroundColor, in: Circle())
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .animation(Theme.quickSpring, value: isActive)
    }

    private var foregroundColor: Color {
        if isDestructive { return .white }
        return isActive ? .black : Theme.textPrimary
    }

    private var backgroundColor: Color {
        if isDestructive { return Theme.record }
        return isActive ? Theme.accent : Color.black.opacity(0.45)
    }
}

/// Pill-shaped record indicator with a pulsing dot, used in camera chrome and recording lists.
struct RecordingIndicator: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    @State private var pulse = false

    var body: some View {
        if isRecording {
            HStack(spacing: Theme.spacingS) {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 10, height: 10)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
                Text(elapsed.asTimecode)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, Theme.spacingS)
            .background(Color.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(Theme.record.opacity(0.6), lineWidth: 1))
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
            .background(filled ? color : color.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.5), lineWidth: 1))
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
