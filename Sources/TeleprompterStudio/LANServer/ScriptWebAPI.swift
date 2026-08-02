import Foundation
import SwiftData

/// Bridges the LAN HTTP router to SwiftData. All `ModelContext` access happens on the main
/// actor (SwiftData's contract); the HTTP layer awaits these calls from its own background
/// queue.
@MainActor
enum ScriptWebAPI {
    static func listScripts(container: ModelContainer) -> [[String: Any]] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Script>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let scripts = (try? context.fetch(descriptor)) ?? []
        return scripts.map(summaryJSON)
    }

    static func getScript(id: String, container: ModelContainer) -> [String: Any]? {
        guard let script = fetchScript(id: id, container: container) else { return nil }
        return detailJSON(script)
    }

    static func createScript(title: String, markdown: String, container: ModelContainer) -> [String: Any] {
        let context = container.mainContext
        let script = Script(title: title.isEmpty ? "Untitled Script" : title, bodyMarkdown: markdown)
        script.style = ScriptStyle()
        context.insert(script)
        try? context.save()
        return detailJSON(script)
    }

    @discardableResult
    static func updateScript(id: String, title: String?, markdown: String?, container: ModelContainer) -> [String: Any]? {
        guard let script = fetchScript(id: id, container: container) else { return nil }
        if let title { script.title = title }
        if let markdown { script.bodyMarkdown = markdown }
        script.touch()
        try? container.mainContext.save()
        return detailJSON(script)
    }

    static func deleteScript(id: String, container: ModelContainer) -> Bool {
        guard let script = fetchScript(id: id, container: container) else { return false }
        container.mainContext.delete(script)
        try? container.mainContext.save()
        return true
    }

    private static func fetchScript(id: String, container: ModelContainer) -> Script? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let context = container.mainContext
        let descriptor = FetchDescriptor<Script>(predicate: #Predicate { $0.id == uuid })
        return try? context.fetch(descriptor).first
    }

    private static func summaryJSON(_ script: Script) -> [String: Any] {
        [
            "id": script.id.uuidString,
            "title": script.title,
            "firstLine": script.firstLine,
            "wordCount": script.wordCount,
            "updatedAt": ISO8601DateFormatter().string(from: script.updatedAt),
        ]
    }

    private static func detailJSON(_ script: Script) -> [String: Any] {
        var json = summaryJSON(script)
        json["bodyMarkdown"] = script.bodyMarkdown
        if let style = script.style {
            json["style"] = [
                "fontName": style.fontName,
                "baseSize": style.baseSize,
                "lineHeight": style.lineHeight,
                "textColorHex": style.textColorHex,
                "bgColorHex": style.bgColorHex,
                "accentColorHex": style.accentColorHex,
            ]
        }
        return json
    }
}
