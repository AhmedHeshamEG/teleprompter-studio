import PhotosUI
import UIKit
import SwiftUI
import SwiftData

struct EditorView: View {
    @Bindable var script: Script
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var showingStylePanel = false
    @State private var showingStudio = false
    @State private var showingVoiceStudio = false
    @State private var showingPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var saveWorkItem: DispatchWorkItem?
    /// Must stay stable across body re-evaluations (every keystroke) so scroll/play state
    /// doesn't reset on every edit.
    @State private var previewController = PrompterController()

    private var style: ScriptStyle {
        if let style = script.style { return style }
        let created = ScriptStyle()
        script.style = created
        return created
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                apply: { transform in applyFormat(transform) },
                insertPicture: { showingPhotoPicker = true }
            )

            GeometryReader { proxy in
                if proxy.size.width > 700 {
                    HStack(spacing: 0) {
                        editorPane
                            .frame(width: proxy.size.width * 0.5)
                        Divider()
                        previewPane
                    }
                } else {
                    editorPane
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Untitled Script", text: $script.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .onChange(of: script.title) { _, _ in scheduleSave() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingStylePanel = true
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                // Same script, no camera: a full-screen prompter over a lossless voice recorder.
                Button {
                    showingVoiceStudio = true
                } label: {
                    Label("Voice", systemImage: "mic.fill")
                }
                Button {
                    showingStudio = true
                } label: {
                    Label("Go Live", systemImage: "video.fill")
                }
                .tint(Theme.accent)
            }
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task { await insertPicture(from: item) }
        }
        .sheet(isPresented: $showingStylePanel) {
            StylePanelView(style: style)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showingStudio) {
            StudioView(script: script)
                .environment(appState)
        }
        .fullScreenCover(isPresented: $showingVoiceStudio) {
            VoiceStudioView(script: script)
        }
        .onChange(of: script.bodyMarkdown) { _, _ in scheduleSave() }
    }

    private var editorPane: some View {
        MarkdownTextView(text: $script.bodyMarkdown, selectedRange: $selectedRange)
            .padding(.horizontal, Theme.spacingXS)
    }

    private var previewPane: some View {
        NativePrompterView(
            document: PrompterDocument(markdown: script.bodyMarkdown, style: style),
            controller: previewController,
            isInteractivePreview: true
        )
        .background(HexColor.color(style.bgColorHex))
    }

    private func applyFormat(_ transform: (String, NSRange) -> MarkdownFormatter.Result) {
        let result = transform(script.bodyMarkdown, selectedRange)
        script.bodyMarkdown = result.text
        selectedRange = result.selection
        scheduleSave()
    }

    /// Copies the picked photo into the script's picture store and drops its link on a line of its
    /// own at the cursor. The editor then shows it as the picture, the prompter as the picture.
    private func insertPicture(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              // Off the main thread: downscaling a 48MP photo is not a keystroke-sized job.
              let id = try? await Task.detached(priority: .userInitiated, operation: { try ScriptImageStore.save(image) }).value
        else { return }
        let token = ScriptImageMarkup.token(for: id)
        applyFormat { text, range in
            MarkdownFormatter.insertOnOwnLine(text: text, range: range, block: token)
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            script.touch()
            try? modelContext.save()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }
}
