import SwiftUI
import SwiftData

struct EditorView: View {
    @Bindable var script: Script
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var showingStylePanel = false
    @State private var showingStudio = false
    @State private var saveWorkItem: DispatchWorkItem?
    /// Must stay stable across body re-evaluations (every keystroke) — a fresh
    /// `PrompterController` on each render would never get attached to the live WKWebView.
    @State private var previewController = PrompterController()

    private var style: ScriptStyle {
        if let style = script.style { return style }
        let created = ScriptStyle()
        script.style = created
        return created
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar { transform in
                applyFormat(transform)
            }

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
                Button {
                    showingStudio = true
                } label: {
                    Label("Go Live", systemImage: "video.fill")
                }
                .tint(Theme.accent)
            }
        }
        .sheet(isPresented: $showingStylePanel) {
            StylePanelView(style: style)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showingStudio) {
            StudioView(script: script)
                .environment(appState)
        }
        .onChange(of: script.bodyMarkdown) { _, _ in scheduleSave() }
    }

    private var editorPane: some View {
        MarkdownTextView(text: $script.bodyMarkdown, selectedRange: $selectedRange)
            .padding(.horizontal, Theme.spacingXS)
    }

    private var previewPane: some View {
        PrompterWebView(
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
