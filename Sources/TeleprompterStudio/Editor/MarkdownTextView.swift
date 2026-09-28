import SwiftUI
import UIKit

/// A `UITextView`-backed editor so the toolbar has access to true selection ranges
/// (SwiftUI's `TextEditor` does not expose text selection on iOS 17).
///
/// Script pictures (`![](tp-image:…)`, see `ScriptImageMarkup`) are shown as the picture itself —
/// one attachment character in the view standing in for the whole link in the Markdown. The
/// bindings stay in **Markdown** terms (the text *and* the selection), so the toolbar's formatters
/// never have to know pictures exist: this view translates offsets both ways.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var onCommandInsert: ((MarkdownTextView.Coordinator) -> Void)?

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular),
        .foregroundColor: UIColor.white,
    ]

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = .white
        textView.tintColor = UIColor(Theme.accent)
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .default
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.alwaysBounceVertical = true
        context.coordinator.textView = textView
        context.coordinator.load(text, into: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.markdown != text {
            let previousSelection = coordinator.markdownRange(for: uiView.selectedRange)
            coordinator.load(text, into: uiView)
            coordinator.select(previousSelection, in: uiView)
        }
        let wanted = selectedRange
        if wanted.location != NSNotFound, coordinator.markdownRange(for: uiView.selectedRange) != wanted {
            coordinator.select(wanted, in: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: UITextView?
        /// The Markdown the view currently shows — compared against the binding instead of
        /// re-serialising the view on every SwiftUI update.
        private(set) var markdown = ""
        /// Picture links in the current Markdown, in order: where each one sits in the *view*
        /// (one attachment character) and how long its link is in the Markdown.
        private var pictures: [(viewLocation: Int, markdownLength: Int)] = []
        /// Set while this coordinator itself is changing the view, so the selection callbacks that
        /// UIKit fires for programmatic changes don't write back into SwiftUI mid-update.
        private var isApplyingChange = false

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        // MARK: Markdown <-> view

        func load(_ text: String, into textView: UITextView) {
            let ns = text as NSString
            let built = NSMutableAttributedString()
            var found: [(Int, Int)] = []
            var cursor = 0
            for match in ScriptImageMarkup.matches(in: text) {
                if match.range.location > cursor {
                    built.append(NSAttributedString(
                        string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                        attributes: MarkdownTextView.baseAttributes
                    ))
                }
                if let image = ScriptImageStore.image(for: match.id) {
                    found.append((built.length, match.range.length))
                    let attachment = ScriptImageAttachment(imageID: match.id, image: image, boxAspect: 0.5)
                    let piece = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    piece.addAttributes(MarkdownTextView.baseAttributes, range: NSRange(location: 0, length: piece.length))
                    built.append(piece)
                } else {
                    // File missing: keep the link as editable text so nothing is silently lost.
                    built.append(NSAttributedString(string: ns.substring(with: match.range), attributes: MarkdownTextView.baseAttributes))
                }
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                built.append(NSAttributedString(string: ns.substring(from: cursor), attributes: MarkdownTextView.baseAttributes))
            }
            markdown = text
            pictures = found
            isApplyingChange = true
            textView.attributedText = built
            textView.typingAttributes = MarkdownTextView.baseAttributes
            isApplyingChange = false
        }

        /// Reads the view back into Markdown: every picture attachment becomes its link again.
        private func serialize(_ textView: UITextView) -> String {
            let attributed = textView.attributedText ?? NSAttributedString()
            let ns = attributed.string as NSString
            var output = ""
            var found: [(Int, Int)] = []
            var cursor = 0
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard value != nil else { return }
                if range.location > cursor {
                    output += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                }
                for offset in 0..<range.length {
                    // Anything that isn't one of ours (pasted in from elsewhere) has no file behind
                    // it and no link to become, so it's dropped rather than saved as a stray U+FFFC.
                    if let picture = attributed.attribute(.attachment, at: range.location + offset, effectiveRange: nil) as? ScriptImageAttachment {
                        let token = ScriptImageMarkup.token(for: picture.imageID)
                        found.append((range.location + offset, (token as NSString).length))
                        output += token
                    }
                }
                cursor = range.location + range.length
            }
            if cursor < ns.length { output += ns.substring(from: cursor) }
            pictures = found
            return output
        }

        private func markdownLocation(forView location: Int) -> Int {
            var shift = 0
            for picture in pictures where picture.viewLocation < location {
                shift += picture.markdownLength - 1
            }
            return location + shift
        }

        private func viewLocation(forMarkdown location: Int) -> Int {
            var shift = 0
            for picture in pictures {
                let start = picture.viewLocation + shift
                if location <= start { break }
                // Inside a link: land just after the picture.
                if location < start + picture.markdownLength {
                    return picture.viewLocation + 1
                }
                shift += picture.markdownLength - 1
            }
            return location - shift
        }

        func markdownRange(for viewRange: NSRange) -> NSRange {
            let start = markdownLocation(forView: viewRange.location)
            let end = markdownLocation(forView: viewRange.location + viewRange.length)
            return NSRange(location: start, length: end - start)
        }

        func select(_ markdownRange: NSRange, in textView: UITextView) {
            let length = textView.attributedText.length
            let start = min(viewLocation(forMarkdown: markdownRange.location), length)
            let end = min(max(start, viewLocation(forMarkdown: markdownRange.location + markdownRange.length)), length)
            let range = NSRange(location: start, length: end - start)
            guard textView.selectedRange != range else { return }
            isApplyingChange = true
            textView.selectedRange = range
            isApplyingChange = false
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            self.textView = textView
            markdown = serialize(textView)
            if textView.typingAttributes[.attachment] != nil {
                textView.typingAttributes = MarkdownTextView.baseAttributes
            }
            parent.text = markdown
            // UIKit reports the new selection *before* this callback, i.e. against the old picture
            // positions; restate it now that they're current.
            parent.selectedRange = markdownRange(for: textView.selectedRange)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            self.textView = textView
            guard !isApplyingChange else { return }
            parent.selectedRange = markdownRange(for: textView.selectedRange)
        }
    }
}
