import Foundation

/// Strips Markdown/HTML syntax down to plain readable text. Scripts written before the inline
/// HTML-coloring editor feature was removed may still contain leftover `<span style="color:...">`,
/// `<mark>`, `**bold**`, etc. in their saved body — this guarantees the prompter never shows that
/// raw syntax on screen, regardless of what's stored.
enum PlainTextRenderer {
    static func plainText(from markdown: String) -> String {
        var text = markdown
        text = replacing(in: text, pattern: "<[^>]+>", with: "")
        text = replacing(in: text, pattern: "\\*\\*([^*]+)\\*\\*", with: "$1")
        text = replacing(in: text, pattern: "\\*([^*]+)\\*", with: "$1")
        text = replacing(in: text, pattern: "(?m)^#{1,6}\\s+", with: "")
        text = replacing(in: text, pattern: "\\${1,2}", with: "")

        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func replacing(in text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
