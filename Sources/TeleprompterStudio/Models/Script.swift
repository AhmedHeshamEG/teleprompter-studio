import Foundation
import SwiftData

@Model
final class Script {
    var id: UUID = UUID()
    var title: String = "Untitled Script"
    /// Canonical content format: Markdown with inline (`$...$`) / block (`$$...$$`) LaTeX.
    var bodyMarkdown: String = ""
    var folder: Folder?
    var tags: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ScriptStyle.script)
    var style: ScriptStyle?

    /// Marker positions expressed as 0...1 fractional scroll offsets into the rendered document,
    /// so they remain stable across devices/font sizes without native layout math.
    var markers: [ScriptMarker] = []

    @Relationship(deleteRule: .cascade, inverse: \Recording.script)
    var recordings: [Recording] = []

    init(
        title: String = "Untitled Script",
        bodyMarkdown: String = "",
        folder: Folder? = nil,
        tags: [String] = []
    ) {
        self.id = UUID()
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.folder = folder
        self.tags = tags
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var wordCount: Int {
        bodyMarkdown.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Estimated read time at an average conversational prompter pace of ~135 WPM.
    var estimatedReadSeconds: Double {
        Double(wordCount) / 135.0 * 60.0
    }

    var firstLine: String {
        let stripped = bodyMarkdown
            .split(separator: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        return String(stripped).trimmingCharacters(in: .whitespaces)
    }

    func touch() {
        updatedAt = Date()
    }
}

/// Codable value type stored inline on `Script` for named jump points.
struct ScriptMarker: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var scrollFraction: Double // 0...1
}
