import SwiftData
import SwiftUI

extension Recording {
    /// Voice takes are the `.m4a` files; video takes share the model and the folder.
    var isVoiceTake: Bool { relativePath.lowercased().hasSuffix(".m4a") }

    /// The file name without its extension — renaming a take renames its file, so what the list
    /// shows is exactly what the Files app shows.
    var displayName: String { (relativePath as NSString).deletingPathExtension }
}

extension Script {
    var voiceTakes: [Recording] {
        recordings.filter(\.isVoiceTake).sorted { $0.createdAt > $1.createdAt }
    }
}

enum VoiceTakeFiles {
    /// Renames the take's file (and so its name everywhere). Returns false if the name is empty
    /// or the file couldn't be moved.
    @MainActor
    static func rename(_ take: Recording, to newName: String, in context: ModelContext) -> Bool {
        let base = VoiceRecorder.safeFileName(newName)
        guard !base.isEmpty, base != take.displayName else { return false }
        let directory = VoiceRecorder.recordingsDirectory
        var candidate = base + ".m4a"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(counter).m4a"
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: take.fileURL(), to: directory.appendingPathComponent(candidate))
        } catch {
            return false
        }
        take.relativePath = candidate
        try? context.save()
        return true
    }

    @MainActor
    static func delete(_ take: Recording, in context: ModelContext) {
        try? FileManager.default.removeItem(at: take.fileURL())
        context.delete(take)
        try? context.save()
    }
}

/// Every voice take of a script, Voice Memos style: newest first, tap one to open its player
/// (waveform scrubber, ±5 s, speed), swipe to delete, rename from the menu, share anywhere.
struct VoiceTakesView: View {
    let script: Script
    let player: TakePlayer
    @Binding var selectedID: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var renaming: Recording?
    @State private var renameText = ""
    @State private var pendingDelete: Recording?

    var body: some View {
        NavigationStack {
            let takes = script.voiceTakes
            Group {
                if takes.isEmpty {
                    EmptyStateView(
                        systemImage: "waveform",
                        title: "No Takes Yet",
                        message: "Tap the record button to record this script. Every take lands here and in the Files app."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(takes, id: \.id) { take in
                            VoiceTakeRow(
                                take: take,
                                player: player,
                                isSelected: selectedID == take.id,
                                onSelect: { select(take) },
                                onRename: { beginRename(take) },
                                onDelete: { pendingDelete = take }
                            )
                            .listRowBackground(selectedID == take.id ? Theme.surfaceElevated : Theme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(take) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .animation(Theme.quickSpring, value: selectedID)
                }
            }
            .background(Theme.background)
            .navigationTitle("Takes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Rename Take", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { commitRename() }
        }
        .confirmationDialog(
            "Delete this take?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Take", role: .destructive) {
                if let take = pendingDelete { delete(take) }
                pendingDelete = nil
            }
        } message: {
            Text("The file is removed from the Files app too.")
        }
        .onAppear {
            if selectedID == nil, let first = script.voiceTakes.first { select(first) }
        }
    }

    private func select(_ take: Recording) {
        guard selectedID != take.id else { return }
        if player.loadedID != take.id { player.pause() }
        selectedID = take.id
        player.load(url: take.fileURL(), id: take.id, title: take.displayName)
    }

    private func beginRename(_ take: Recording) {
        renameText = take.displayName
        renaming = take
    }

    private func commitRename() {
        guard let take = renaming else { return }
        renaming = nil
        let wasLoaded = player.loadedID == take.id
        if wasLoaded { player.unload() }
        _ = VoiceTakeFiles.rename(take, to: renameText, in: modelContext)
        if wasLoaded { player.load(url: take.fileURL(), id: take.id, title: take.displayName) }
    }

    private func delete(_ take: Recording) {
        if player.loadedID == take.id { player.unload() }
        if selectedID == take.id { selectedID = nil }
        VoiceTakeFiles.delete(take, in: modelContext)
    }
}

private struct VoiceTakeRow: View {
    let take: Recording
    let player: TakePlayer
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(take.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(take.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if !isSelected {
                    Text(take.durationSec.asTimecode)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            if isSelected {
                TakePlayerPanel(take: take, player: player, onRename: onRename, onDelete: onDelete)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
    }
}

/// The expanded player under a selected take.
struct TakePlayerPanel: View {
    let take: Recording
    let player: TakePlayer
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var samples: [Float] = []

    private var isLoaded: Bool { player.loadedID == take.id }

    var body: some View {
        VStack(spacing: Theme.spacingS) {
            WaveformScrubber(
                samples: samples,
                progress: isLoaded ? player.progress : 0,
                onSeek: { fraction in
                    ensureLoaded()
                    player.seek(toFraction: fraction)
                }
            )
            .frame(height: 48)

            HStack {
                Text((isLoaded ? player.currentTime : 0).asTimecode)
                Spacer()
                Text("-" + (take.durationSec - (isLoaded ? player.currentTime : 0)).asTimecode)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 0) {
                ShareLink(item: take.fileURL()) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share take")

                Spacer()

                Button {
                    ensureLoaded()
                    player.skip(by: -TakePlayer.skipInterval)
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Back 5 seconds")

                Button {
                    ensureLoaded()
                    player.toggle()
                } label: {
                    Image(systemName: isLoaded && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .regular))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 64, height: 56)
                }
                .accessibilityLabel(isLoaded && player.isPlaying ? "Pause" : "Play")

                Button {
                    ensureLoaded()
                    player.skip(by: TakePlayer.skipInterval)
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Forward 5 seconds")

                Spacer()

                Menu {
                    Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                        ForEach(TakePlayer.rates, id: \.self) { rate in
                            Text(rate == 1 ? "Normal Speed" : "\(rate.formatted())×").tag(rate)
                        }
                    }
                    if let onRename {
                        Button("Rename", systemImage: "pencil", action: onRename)
                    }
                    if let onDelete {
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More")
            }
            .foregroundStyle(Theme.textPrimary)
            .buttonStyle(.borderless)
        }
        .task(id: take.relativePath) {
            samples = await WaveformLoader.load(url: take.fileURL(), bars: 90)
        }
    }

    private func ensureLoaded() {
        if !isLoaded {
            player.load(url: take.fileURL(), id: take.id, title: take.displayName)
        }
    }
}
