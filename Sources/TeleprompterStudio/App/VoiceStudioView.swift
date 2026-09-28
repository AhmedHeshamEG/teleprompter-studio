import AVFoundation
import SwiftData
import SwiftUI

/// Voice mode: the same script and the same prompter as Studio, with the camera swapped for a
/// lossless voice recorder. For voice-overs, podcasts, narration — anything where the words matter
/// and the picture doesn't.
///
/// The recorder half follows Voice Memos, because that's the recorder everyone already knows: a
/// live waveform with the playhead in the middle, a big clock to the hundredth, pause/resume into
/// the same file, discard, and a takes list with a scrubbable player. The prompter half follows
/// Studio: portrait stacks it all, landscape moves the recorder into a side rail (a landscape
/// iPhone has ~390pt of height and none of it spare), and every value that ticks is read inside
/// its own small view so it never rebuilds the prompter.
struct VoiceStudioView: View {
    let script: Script
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var recorder = VoiceRecorder()
    @State private var player = TakePlayer()
    @State private var prompter = PrompterController()
    @State private var document: PrompterDocument
    @State private var showingSliders = false
    @State private var showingTakes = false
    @State private var selectedTakeID: UUID?
    @State private var isArmed = false
    @State private var armTask: Task<Void, Never>?
    @State private var confirmingDiscard = false
    @State private var confirmingClose = false
    @State private var inputPickerTrigger = 0
    @AppStorage("voice.countdown") private var useCountdown = true

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
        .background {
            if #available(iOS 26.0, *) {
                SystemInputPickerHost(trigger: inputPickerTrigger).frame(width: 1, height: 1)
            }
        }
        .statusBarHidden()
        .keepsScreenAwake()
        .preferredColorScheme(.dark)
        .sensoryFeedback(trigger: recorder.state) { old, new in
            switch (old, new) {
            case (.idle, .recording): return .start
            case (_, .idle): return .stop
            case (.recording, .paused), (.paused, .recording): return .impact(weight: .medium)
            default: return nil
            }
        }
        .task {
            prompter.loadDocument(document)
            _ = await recorder.prepare()
        }
        .onDisappear {
            armTask?.cancel()
            finishTakeIfNeeded()
            player.unload()
            recorder.teardown()
        }
        .sheet(isPresented: $showingTakes) {
            VoiceTakesView(script: script, player: player, selectedID: $selectedTakeID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Discard this take?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Take", role: .destructive) { discardTake() }
        } message: {
            Text("The recording so far will be deleted.")
        }
        .confirmationDialog("You're in the middle of a take", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Save Take and Close") {
                finishTakeIfNeeded()
                dismiss()
            }
            Button("Discard Take", role: .destructive) {
                discardTake()
                dismiss()
            }
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
                closeButton
                Spacer()
                VStack(spacing: 0) {
                    Text(script.title.isEmpty ? "Voice" : script.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("Voice")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                }
                Spacer()
                optionsMenu
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.top, Theme.spacingS)

            prompterSurface
                .padding(.horizontal, Theme.spacingS)
                .padding(.top, Theme.spacingS)

            PrompterControlsView(controller: prompter, showingSliders: $showingSliders)

            recorderPanel(compact: false)
                .padding(.horizontal, Theme.spacingS)
                .padding(.bottom, Theme.spacingS)
        }
    }

    private var landscape: some View {
        HStack(spacing: 0) {
            VStack(spacing: Theme.spacingM) {
                closeButton
                optionsMenu
                Spacer()
            }
            .padding(.leading, Theme.spacingS)
            .padding(.vertical, Theme.spacingS)

            VStack(spacing: 0) {
                prompterSurface
                    .padding(.horizontal, Theme.spacingS)
                    .padding(.top, Theme.spacingS)
                PrompterControlsView(controller: prompter, showingSliders: $showingSliders)
            }

            recorderPanel(compact: true)
                .frame(width: 250)
                .padding(.vertical, Theme.spacingS)
                .padding(.trailing, Theme.spacingS)
        }
    }

    private var closeButton: some View {
        ChromeButton(systemImage: "xmark", size: Theme.minControlSizeCompact) {
            if recorder.isRecording {
                confirmingClose = true
            } else {
                dismiss()
            }
        }
        .accessibilityLabel("Close")
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

    // MARK: Recorder panel

    /// The Voice Memos card: waveform, clock, and the three controls. Idle, the left control opens
    /// the takes and the latest take sits ready to play; mid-take, it's discard | stop | pause.
    private func recorderPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? Theme.spacingS : Theme.spacingM) {
            if !recorder.isRecording, let latest = script.voiceTakes.first {
                LatestTakeStrip(take: latest, player: player) {
                    selectedTakeID = latest.id
                    showingTakes = true
                }
            } else {
                LiveWaveformView(recorder: recorder)
                    .frame(height: compact ? 56 : 72)
            }

            VStack(spacing: 2) {
                VoiceClock(recorder: recorder, size: compact ? 34 : 44)
                VoiceStatusLine(recorder: recorder)
            }

            HStack {
                leadingControl.frame(maxWidth: .infinity)
                RecordButton(isRecording: recorder.isRecording, isArmed: isArmed) { toggleRecording() }
                    .accessibilityLabel(recorder.isRecording ? "Stop and save take" : "Record")
                trailingControl.frame(maxWidth: .infinity)
            }
        }
        .padding(compact ? Theme.spacingS : Theme.spacingM)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        .animation(Theme.quickSpring, value: recorder.state)
    }

    @ViewBuilder
    private var leadingControl: some View {
        if recorder.isRecording {
            VoiceRoundButton(systemImage: "trash", label: "Discard take") { confirmingDiscard = true }
        } else {
            let count = script.voiceTakes.count
            VoiceRoundButton(systemImage: "list.bullet", label: "Takes, \(count)") { showingTakes = true }
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.accent, in: Capsule())
                            .offset(x: -2, y: 2)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if recorder.isRecording {
            VoiceRoundButton(
                systemImage: recorder.isPaused ? "record.circle" : "pause.fill",
                label: recorder.isPaused ? "Resume" : "Pause",
                tint: recorder.isPaused ? Theme.record : nil
            ) {
                togglePause()
            }
        } else {
            Color.clear.frame(width: 48, height: 48)
        }
    }

    // MARK: Options

    /// Everything that's set once and left alone lives here, out of the way of the take: the mic,
    /// Voice Isolation (off unless you want it) and the countdown.
    private var optionsMenu: some View {
        Menu {
            Section("Microphone") {
                if #available(iOS 26.0, *) {
                    Button("Choose Input…", systemImage: "mic.badge.plus") { inputPickerTrigger += 1 }
                }
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
            }
            Section {
                Toggle(isOn: Binding(
                    get: { recorder.voiceIsolationEnabled },
                    set: { enabled in
                        recorder.voiceIsolationEnabled = enabled
                        // The mode itself is Apple's to set: offer the system panel straight away
                        // when it isn't already on Voice Isolation.
                        if enabled, AVCaptureDevice.preferredMicrophoneMode != .voiceIsolation {
                            recorder.showSystemMicModes()
                        }
                    }
                )) {
                    Label("Voice Isolation", systemImage: "person.wave.2")
                }
                if recorder.voiceIsolationEnabled {
                    Button("Mic Mode…", systemImage: "slider.horizontal.below.rectangle") {
                        recorder.showSystemMicModes()
                    }
                }
            } header: {
                // Menus drop section footers, so the trade-off lives in the header.
                Text("Off: untouched, lossless · On: Apple's voice processing")
            }
            Section {
                Toggle(isOn: $useCountdown) {
                    Label("3-2-1 Countdown", systemImage: "timer")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
                .chromeGlass(in: Circle())
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .disabled(recorder.isRecording)
        .accessibilityLabel("Recording options")
    }

    // MARK: Actions

    /// Tap to record (after the optional 3-2-1, which starts the prompter with it); tap again to
    /// stop and keep the take. Tapping during the count calls it off.
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
        player.pause()
        recorder.errorMessage = nil
        guard useCountdown else {
            beginTake()
            prompter.play()
            return
        }
        isArmed = true
        prompter.startCountdown(seconds: 3)
        armTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isArmed = false
            beginTake()
        }
    }

    private func beginTake() {
        do {
            try recorder.start(scriptTitle: script.title)
        } catch {
            recorder.errorMessage = error.localizedDescription
            prompter.pause()
        }
    }

    /// Pausing the take pauses the script with it, and resuming picks both up together.
    private func togglePause() {
        if recorder.isPaused {
            recorder.resume()
            if recorder.state == .recording { prompter.play() }
        } else {
            recorder.pause()
            prompter.pause()
        }
    }

    private func discardTake() {
        recorder.discard()
        prompter.pause()
    }

    private func finishTakeIfNeeded() {
        guard recorder.isRecording, let take = recorder.stop() else { return }
        let recording = recorder.saveTake(take.url, duration: take.duration, script: script, in: modelContext)
        selectedTakeID = recording.id
    }
}

/// The take you just recorded, ready to hear back without opening the list: play/pause, where
/// you are in it, and a tap-through to all takes.
private struct LatestTakeStrip: View {
    let take: Recording
    let player: TakePlayer
    let openTakes: () -> Void

    private var isLoaded: Bool { player.loadedID == take.id }

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            Button {
                if !isLoaded { player.load(url: take.fileURL(), id: take.id, title: take.displayName) }
                player.toggle()
            } label: {
                Image(systemName: isLoaded && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .background(Theme.textPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLoaded && player.isPlaying ? "Pause last take" : "Play last take")

            Button(action: openTakes) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(take.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        ProgressView(value: isLoaded ? player.progress : 0)
                            .tint(Theme.textPrimary)
                        Text(isLoaded
                             ? "\(player.currentTime.asTimecode) / \(take.durationSec.asTimecode)"
                             : take.durationSec.asTimecode)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all takes")
        }
        .padding(.horizontal, Theme.spacingXS)
        .frame(minHeight: 56)
    }
}
