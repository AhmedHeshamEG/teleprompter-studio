import Foundation

/// Pure text-transformation logic backing the editor toolbar. Operates on `NSString`-index
/// ranges (UTF-16, matching `UITextView.selectedRange`) and returns the new text plus a
/// selection range positioned sensibly after the edit.
enum MarkdownFormatter {
    struct Result {
        let text: String
        let selection: NSRange
    }

    /// Wraps (or, if already wrapped, unwraps) the selection with `prefix`/`suffix` tokens.
    /// If there is no selection, inserts the tokens with the cursor placed between them.
    static func toggleWrap(text: String, range: NSRange, prefix: String, suffix: String) -> Result {
        let ns = text as NSString
        let safeRange = ns.clampedRange(range)
        let selected = ns.substring(with: safeRange)

        // Already wrapped exactly? Unwrap.
        if selected.hasPrefix(prefix), selected.hasSuffix(suffix), selected.count >= prefix.count + suffix.count {
            let inner = String(selected.dropFirst(prefix.count).dropLast(suffix.count))
            let newText = ns.replacingCharacters(in: safeRange, with: inner)
            let newSelection = NSRange(location: safeRange.location, length: (inner as NSString).length)
            return Result(text: newText, selection: newSelection)
        }

        // Check for surrounding tokens just outside the selection (toggle off case).
        let expandedStart = safeRange.location - (prefix as NSString).length
        let expandedEnd = safeRange.location + safeRange.length + (suffix as NSString).length
        if expandedStart >= 0, expandedEnd <= ns.length {
            let before = ns.substring(with: NSRange(location: expandedStart, length: (prefix as NSString).length))
            let after = ns.substring(with: NSRange(location: safeRange.location + safeRange.length, length: (suffix as NSString).length))
            if before == prefix, after == suffix {
                let outerRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)
                let newText = ns.replacingCharacters(in: outerRange, with: selected)
                let newSelection = NSRange(location: expandedStart, length: (selected as NSString).length)
                return Result(text: newText, selection: newSelection)
            }
        }

        let replacement = prefix + selected + suffix
        let newText = ns.replacingCharacters(in: safeRange, with: replacement)
        let newSelection = selected.isEmpty
            ? NSRange(location: safeRange.location + (prefix as NSString).length, length: 0)
            : NSRange(location: safeRange.location, length: (replacement as NSString).length)
        return Result(text: newText, selection: newSelection)
    }

    /// Toggles a leading-line token (e.g. `"# "`, `"## "`) on every line touched by the selection.
    static func toggleLinePrefix(text: String, range: NSRange, token: String) -> Result {
        let ns = text as NSString
        let safeRange = ns.clampedRange(range)
        let lineRange = ns.lineRange(for: safeRange)
        let block = ns.substring(with: lineRange)
        let lines = block.components(separatedBy: "\n")

        let allPrefixed = lines.allSatisfy { $0.isEmpty || $0.hasPrefix(token) }
        let newLines: [String] = lines.map { line in
            guard !line.isEmpty else { return line }
            if allPrefixed {
                return String(line.dropFirst(token.count))
            } else if line.hasPrefix(token) {
                return line
            } else {
                return token + line
            }
        }
        let newBlock = newLines.joined(separator: "\n")
        let newText = ns.replacingCharacters(in: lineRange, with: newBlock)
        let newSelection = NSRange(location: lineRange.location, length: (newBlock as NSString).length)
        return Result(text: newText, selection: newSelection)
    }

    /// Wraps the paragraph(s) touching the selection in an alignment `<div>`.
    static func setAlignment(text: String, range: NSRange, alignment: String) -> Result {
        let ns = text as NSString
        let safeRange = ns.clampedRange(range)
        let lineRange = ns.lineRange(for: safeRange)
        let block = ns.substring(with: lineRange)
        let wrapped = "<div style=\"text-align:\(alignment)\">\n\n\(block)\n\n</div>\n"
        let newText = ns.replacingCharacters(in: lineRange, with: wrapped)
        return Result(text: newText, selection: NSRange(location: lineRange.location, length: (wrapped as NSString).length))
    }

    static func insertInlineMath(text: String, range: NSRange) -> Result {
        toggleWrap(text: text, range: range, prefix: "$", suffix: "$")
    }

    static func insertBlockMath(text: String, range: NSRange) -> Result {
        let ns = text as NSString
        let safeRange = ns.clampedRange(range)
        let selected = ns.substring(with: safeRange)
        let body = selected.isEmpty ? "x^2 + y^2 = z^2" : selected
        let replacement = "\n$$\n\(body)\n$$\n"
        let newText = ns.replacingCharacters(in: safeRange, with: replacement)
        return Result(text: newText, selection: NSRange(location: safeRange.location + 4, length: (body as NSString).length))
    }

    static func applyTextColor(text: String, range: NSRange, hex: String) -> Result {
        toggleWrap(text: text, range: range, prefix: "<span style=\"color:\(hex)\">", suffix: "</span>")
    }

    static func applyHighlight(text: String, range: NSRange, hex: String) -> Result {
        toggleWrap(text: text, range: range, prefix: "<mark style=\"background-color:\(hex)\">", suffix: "</mark>")
    }
}

private extension NSString {
    func clampedRange(_ range: NSRange) -> NSRange {
        let location = max(0, min(range.location, length))
        let maxLength = length - location
        let len = max(0, min(range.length, maxLength))
        return NSRange(location: location, length: len)
    }
}
