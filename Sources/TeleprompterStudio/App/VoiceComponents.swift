import AVKit
import SwiftUI

// Building blocks shared by the Voice screen and its takes list. Each one that shows a ticking
// value reads it in its own body, so the prompter above never rebuilds because a meter moved.

extension TimeInterval {
    /// Voice Memos' clock: `00:12.34`, with hours only when there are any.
    var asPreciseTimecode: String {
        let clamped = max(0, self)
        let hundredths = Int((clamped * 100).rounded(.down)) % 100
        let total = Int(clamped)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, hundredths) }
        return String(format: "%02d:%02d.%02d", m, s, hundredths)
    }
}

/// The live waveform while recording: bars scroll in from the playhead in the middle and drift
/// left, exactly as Voice Memos draws it. The right half stays empty — that's where the recording
/// hasn't happened yet.
struct LiveWaveformView: View {
    let recorder: VoiceRecorder
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 1.5

    var body: some View {
        let history = recorder.levelHistory
        let isActive = recorder.state == .recording
        Canvas { context, size in
            let midY = size.height / 2
            let playheadX = size.width / 2
            let step = barWidth + spacing
            let maxBars = Int(playheadX / step)
            let visible = history.suffix(maxBars)
            for (offset, value) in visible.reversed().enumerated() {
                let x = playheadX - CGFloat(offset + 1) * step
                let height = max(2, CGFloat(value) * size.height * 0.92)
                let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(0.9)))
            }
            // Future: a dotted baseline.
            var baseline = Path()
            baseline.move(to: CGPoint(x: playheadX, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            // Playhead.
            let head = CGRect(x: playheadX - 1, y: 0, width: 2, height: size.height)
            context.fill(Path(roundedRect: head, cornerRadius: 1), with: .color(isActive ? Theme.record : Theme.textTertiary))
        }
        .accessibilityHidden(true)
    }
}

/// Big take clock.
struct VoiceClock: View {
    let recorder: VoiceRecorder
    var size: CGFloat = 44

    var body: some View {
        Text(recorder.elapsed.asPreciseTimecode)
            .font(.system(size: size, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(recorder.isPaused ? Theme.textSecondary : Theme.textPrimary)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel("Take length \(recorder.elapsed.asTimecode)")
    }
}

/// One line under the clock: what's recording and how. Paused/interrupted states take it over.
struct VoiceStatusLine: View {
    let recorder: VoiceRecorder

    var body: some View {
        HStack(spacing: 6) {
            if recorder.isInterrupted {
                Label("Interrupted", systemImage: "phone.fill").foregroundStyle(Theme.warning)
            } else if recorder.isPaused {
                Label("Paused", systemImage: "pause.fill").foregroundStyle(Theme.warning)
            } else {
                Image(systemName: "mic.fill")
                Text(recorder.inputName)
                    .lineLimit(1)
                Text("·")
                Text(recorder.isRecording && recorder.takeUsesVoiceProcessing
                     ? (recorder.activeMicModeName ?? "Voice Isolation")
                     : "Lossless")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
        .labelStyle(.titleAndIcon)
    }
}

/// A take's waveform you can scrub: played part bright, the rest dim, drag anywhere to seek.
struct WaveformScrubber: View {
    let samples: [Float]
    let progress: Double
    let onSeek: (Double) -> Void
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let shown = dragFraction ?? progress
            Canvas { context, size in
                let count = max(samples.count, 1)
                let step = size.width / CGFloat(count)
                let barWidth = max(1, step * 0.6)
                let midY = size.height / 2
                for (index, value) in samples.enumerated() {
                    let x = CGFloat(index) * step
                    let height = max(2, CGFloat(value) * size.height)
                    let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                    let played = (Double(index) + 0.5) / Double(count) <= shown
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(played ? Theme.textPrimary : Theme.textTertiary)
                    )
                }
                if samples.isEmpty {
                    let line = CGRect(x: 0, y: midY - 1, width: size.width, height: 2)
                    context.fill(Path(line), with: .color(Theme.textTertiary))
                }
                let x = size.width * CGFloat(shown)
                context.fill(
                    Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                    with: .color(Theme.record)
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragFraction == nil { onScrubbingChanged(true) }
                        dragFraction = max(0, min(1, value.location.x / max(proxy.size.width, 1)))
                    }
                    .onEnded { _ in
                        if let dragFraction { onSeek(dragFraction) }
                        dragFraction = nil
                        onScrubbingChanged(false)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(1, progress + 0.05))
            case .decrement: onSeek(max(0, progress - 0.05))
            @unknown default: break
            }
        }
    }
}

/// A small round glass button with a label for VoiceOver — the secondary controls around the
/// record button (pause, discard, takes).
struct VoiceRoundButton: View {
    let systemImage: String
    let label: String
    var tint: Color? = nil
    var size: CGFloat = Theme.minControlSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint == nil ? Theme.textPrimary : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .chromeGlass(in: Circle(), tint: tint)
                .frame(width: max(size, 48), height: max(size, 48))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Apple's own audio-input picker (iOS 26), hosted by an invisible view and opened by bumping
/// `trigger`. It's the same sheet the system uses to pick between the iPhone mic, AirPods and
/// wired mics, with live levels.
@available(iOS 26.0, *)
struct SystemInputPickerHost: UIViewRepresentable {
    let trigger: Int

    final class Coordinator {
        var interaction: AVInputPickerInteraction?
        var lastTrigger = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        let interaction = AVInputPickerInteraction()
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        context.coordinator.lastTrigger = trigger
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard trigger != context.coordinator.lastTrigger else { return }
        context.coordinator.lastTrigger = trigger
        context.coordinator.interaction?.present()
    }
}
