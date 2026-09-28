import AVFoundation
import SwiftData
import SwiftUI

/// Voice mode: the same script and the same prompter as Studio, with the camera swapped for a
/// lossless voice recorder. For voice-overs, podcasts, narration — anything where the words matter
/// and the picture doesn't.
///
/// With no camera preview to protect, the script gets the whole screen. The chrome follows
/// Studio's rules: portrait stacks controls top and bottom, landscape moves them to side rails
/// (a landscape iPhone has ~390pt of height and none of it spare), and every value that ticks —
/// the timer, the meter — is read inside its own small view so it never rebuilds the prompter.
struct VoiceStudioView: View {
    let script: Script
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var recorder = VoiceRecorder()
    @State private var prompter = PrompterController()
    @State private var document: PrompterDocument
    @State private var showingSliders = false
    @State private var isArmed = false
    @State private var armTask: Task<Void, Never>?

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    init(script: Script) {
        self.script = script
        _document = State(initialValue: PrompterDocument(markdown: script.bodyMarkdown, style: script.style ?? ScriptStyle()))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isCompactHeight { landscape } else { portrait }
        }
        .statusBarHidden()
        .keepsScreenAwake()
        .preferredColorScheme(.dark)
        .task {
            prompter.loadDocument(document)
            _ = await recorder.prepare()
        }
        .onDisappear {
            armTask?.cancel()
            finishTakeIfNeeded()
            recorder.teardown()
        }
        .alert("Microphone Access Needed", isPresented: $recorder.isPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access in Settings to record your voice.")
        }
    }

    // MARK: Layouts

    private var portrait: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.spacingM) {
                ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }
                Spacer()
                VoiceStatus(recorder: recorder)
                Spacer()
                VoiceInputMenu(recorder: recorder)
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.top, Theme.spacingS)

            prompterSurface
                .padding(.horizontal, Theme.spacingS)
                .padding(.top, Theme.spacingS)

            VoiceLevelMeter(recorder: recorder)
                .padding(.horizontal, Theme.spacingL)
                .padding(.top, Theme.spacingS)

            PrompterControlsView(controller: prompter, showingSliders: $showingSliders)

            HStack {
                VoiceTakeControls(recorder: recorder)
                    .frame(maxWidth: .infinity)
                recordButton
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
            .padding(.bottom, Theme.spacingM)
        }
    }

    private var landscape: some View {
        HStack(spacing: 0) {
            VStack(spacing: Theme.spacingM) {
                ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) { dismiss() }
                VoiceInputMenu(recorder: recorder)
                Spacer()
            }
            .padding(.leading, Theme.spacingS)
            .padding(.vertical, Theme.spacingS)

            VStack(spacing: 0) {
                HStack(spacing: Theme.spacingM) {
                    VoiceStatus(recorder: recorder)
                    VoiceLevelMeter(recorder: recorder).frame(maxWidth: 220)
                }
                .padding(.top, Theme.spacingS)
                prompterSurface
                    .padding(.horizontal, Theme.spacingS)
                    .padding(.top, Theme.spacingXS)
                PrompterControlsView(controller: prompter, showingSliders: $showingSliders)
            }

            VStack(spacing: Theme.spacingM) {
                Spacer()
                recordButton
                VoiceTakeControls(recorder: recorder, isVertical: true)
                Spacer()
            }
            .padding(.trailing, Theme.spacingS)
        }
    }

    private var prompterSurface: some View {
        NativePrompterView(document: document, controller: prompter)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
            .overlay(alignment: .top) {
                if let message = recorder.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.spacingM)
                        .padding(.vertical, Theme.spacingS)
                        .chromeGlass(in: Capsule())
                        .padding(Theme.spacingS)
                        .onTapGesture { recorder.errorMessage = nil }
                }
            }
    }

    private var recordButton: some View {
        RecordButton(isRecording: recorder.isRecording, isArmed: isArmed) {
            toggleRecording()
        }
    }

    // MARK: Actions

    /// Same rhythm as Studio: tap, 3-2-1 on the prompter, and recording and scrolling start
    /// together. Tapping again during the count calls it off; tapping while recording ends the take.
    private func toggleRecording() {
        if isArmed {
            armTask?.cancel()
            armTask = nil
            isArmed = false
            prompter.cancelCountdown()
            return
        }
        if recorder.isRecording {
            finishTakeIfNeeded()
            prompter.pause()
            return
        }
        recorder.errorMessage = nil
        isArmed = true
        prompter.startCountdown(seconds: 3)
        armTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isArmed = false
            do {
                try recorder.start(scriptTitle: script.title)
            } catch {
                recorder.errorMessage = error.localizedDescription
                prompter.pause()
            }
        }
    }

    private func finishTakeIfNeeded() {
        guard recorder.isRecording, let url = recorder.stop() else { return }
        recorder.saveTake(url, duration: recorder.elapsed, script: script, in: modelContext)
    }
}

// MARK: - Pieces that read ticking values

/// Timer while recording; the take count otherwise.
private struct VoiceStatus: View {
    let recorder: VoiceRecorder

    var body: some View {
        if recorder.isRecording {
            RecordingIndicator(isRecording: true, elapsed: recorder.elapsed)
                .opacity(recorder.isInterrupted ? 0.5 : 1)
        } else {
            Text("Voice")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// A thin, Voice Memos-style level bar: green while it's healthy, yellow near the top, red when
/// it's about to clip.
private struct VoiceLevelMeter: View {
    let recorder: VoiceRecorder

    var body: some View {
        let level = CGFloat(recorder.level)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(level > 0.92 ? Theme.record : (level > 0.75 ? Theme.warning : Theme.success))
                    .frame(width: max(4, proxy.size.width * level))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityHidden(true)
    }
}

/// Which mic to record with: the phone's own, or a wired / USB / Lightning one when attached.
private struct VoiceInputMenu: View {
    let recorder: VoiceRecorder

    var body: some View {
        Menu {
            ForEach(recorder.inputs, id: \.uid) { port in
                Button {
                    recorder.selectInput(port)
                } label: {
                    if port.portName == recorder.inputName {
                        Label(port.portName, systemImage: "checkmark")
                    } else {
                        Text(port.portName)
                    }
                }
            }
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
                .chromeGlass(in: Circle())
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .disabled(recorder.isRecording)
        .accessibilityLabel("Microphone: \(recorder.inputName)")
    }
}

/// Play back and share the take you just recorded — straight to AirDrop, Files, or an editor.
/// Every take is also kept in the Files app under Teleprompter Studio → Recordings.
private struct VoiceTakeControls: View {
    let recorder: VoiceRecorder
    var isVertical: Bool = false

    var body: some View {
        if let take = recorder.lastTake, !recorder.isRecording {
            let layout = isVertical ? AnyLayout(VStackLayout(spacing: Theme.spacingM)) : AnyLayout(HStackLayout(spacing: Theme.spacingM))
            layout {
                ChromeButton(
                    systemImage: recorder.isPlayingLastTake ? "stop.fill" : "play.fill",
                    isActive: recorder.isPlayingLastTake,
                    size: Theme.minControlSizeCompact
                ) {
                    recorder.togglePlayback()
                }
                .accessibilityLabel(recorder.isPlayingLastTake ? "Stop playback" : "Play last take")
                ShareLink(item: take) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
                        .chromeGlass(in: Circle())
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Share last take")
            }
            .transition(.opacity)
        }
    }
}
