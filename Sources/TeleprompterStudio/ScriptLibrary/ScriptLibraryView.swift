import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct ScriptLibraryView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Script.updatedAt, order: .reverse) private var allScripts: [Script]
    @Query(sort: \Folder.order) private var folders: [Folder]

    @State private var searchText = ""
    @State private var selectedFolder: Folder?
    @State private var isGridLayout = true
    @State private var showingImporter = false
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var scriptPendingDelete: Script?
    @State private var navigationScript: Script?

    private var filteredScripts: [Script] {
        var result = allScripts
        if let selectedFolder {
            result = result.filter { $0.folder?.id == selectedFolder.id }
        }
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(needle)
                || $0.bodyMarkdown.lowercased().contains(needle)
                || $0.tags.contains(where: { $0.lowercased().contains(needle) })
            }
        }
        return result
    }

    var body: some View {
        Group {
            if allScripts.isEmpty {
                EmptyStateView(
                    systemImage: "doc.text.magnifyingglass",
                    title: "No Scripts Yet",
                    message: "Paste a script from your clipboard or create a new one to get started.",
                    actionTitle: "Paste Script",
                    action: pasteNewScript
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    folderChips
                    scriptCollection
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Scripts")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search scripts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        pasteNewScript()
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        createScript(title: "Untitled Script", body: "")
                    } label: {
                        Label("New Blank Script", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import from Files", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        showingNewFolderAlert = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    isGridLayout.toggle()
                } label: {
                    Image(systemName: isGridLayout ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.plainText, .utf8PlainText, UTType(filenameExtension: "md") ?? .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") { createFolder() }
        }
        .alert("Delete Script?", isPresented: .constant(scriptPendingDelete != nil), presenting: scriptPendingDelete) { script in
            Button("Cancel", role: .cancel) { scriptPendingDelete = nil }
            Button("Delete", role: .destructive) { delete(script) }
        } message: { script in
            Text("\"\(script.title)\" will be permanently deleted.")
        }
        .navigationDestination(item: $navigationScript) { script in
            EditorView(script: script)
        }
    }

    // MARK: Folder filter chips

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                folderChip(title: "All", isSelected: selectedFolder == nil) { selectedFolder = nil }
                ForEach(folders) { folder in
                    folderChip(title: folder.name, isSelected: selectedFolder?.id == folder.id) {
                        selectedFolder = folder
                    }
                }
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, Theme.spacingS)
        }
    }

    private func folderChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, 6)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .foregroundStyle(isSelected ? .black : Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Script collection

    @ViewBuilder
    private var scriptCollection: some View {
        if isGridLayout {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: Theme.spacingM)], spacing: Theme.spacingM) {
                ForEach(filteredScripts) { script in
                    ScriptCardView(script: script)
                        .onTapGesture { navigationScript = script }
                        .contextMenu { scriptContextMenu(script) }
                }
            }
            .padding(Theme.spacingM)
        } else {
            LazyVStack(spacing: Theme.spacingS) {
                ForEach(filteredScripts) { script in
                    ScriptRowView(script: script)
                        .onTapGesture { navigationScript = script }
                        .contextMenu { scriptContextMenu(script) }
                }
            }
            .padding(Theme.spacingM)
        }
    }

    @ViewBuilder
    private func scriptContextMenu(_ script: Script) -> some View {
        Button {
            duplicate(script)
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }
        Menu("Move to Folder") {
            Button("None") { script.folder = nil }
            ForEach(folders) { folder in
                Button(folder.name) { script.folder = folder }
            }
        }
        Menu("Export") {
            Button("Export as .txt") { export(script, format: .plainText) }
            Button("Export as .md") { export(script, format: .markdown) }
        }
        Button(role: .destructive) {
            scriptPendingDelete = script
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Actions

    private func pasteNewScript() {
        let pasteboardText = UIPasteboard.general.string ?? ""
        createScript(title: Self.deriveTitle(from: pasteboardText), body: pasteboardText)
    }

    private func createScript(title: String, body: String) {
        let script = Script(title: title, bodyMarkdown: body, folder: selectedFolder)
        script.style = ScriptStyle()
        modelContext.insert(script)
        try? modelContext.save()
        navigationScript = script
    }

    private func duplicate(_ script: Script) {
        let copy = Script(title: script.title + " Copy", bodyMarkdown: script.bodyMarkdown, folder: script.folder, tags: script.tags)
        if let style = script.style {
            copy.style = ScriptStyle(
                fontName: style.fontName,
                baseSize: style.baseSize,
                lineHeight: style.lineHeight,
                textColorHex: style.textColorHex,
                bgColorHex: style.bgColorHex,
                accentColorHex: style.accentColorHex
            )
        }
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func delete(_ script: Script) {
        modelContext.delete(script)
        try? modelContext.save()
        scriptPendingDelete = nil
    }

    private func createFolder() {
        guard !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let folder = Folder(name: newFolderName, order: folders.count)
        modelContext.insert(folder)
        try? modelContext.save()
        newFolderName = ""
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        createScript(title: url.deletingPathExtension().lastPathComponent, body: text)
    }

    private enum ExportFormat { case plainText, markdown }

    private func export(_ script: Script, format: ExportFormat) {
        let ext = format == .plainText ? "txt" : "md"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(script.title.replacingOccurrences(of: "/", with: "-"))
            .appendingPathExtension(ext)
        try? script.bodyMarkdown.write(to: tmpURL, atomically: true, encoding: .utf8)

        let activity = UIActivityViewController(activityItems: [tmpURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activity, animated: true)
        }
    }

    private static func deriveTitle(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Pasted Script" }
        return String(trimmed.prefix(60))
    }
}
