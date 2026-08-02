import SwiftUI
import UIKit

/// A `UITextView`-backed editor so the toolbar has access to true selection ranges
/// (SwiftUI's `TextEditor` does not expose text selection on iOS 17).
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var onCommandInsert: ((MarkdownTextView.Coordinator) -> Void)?

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
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            let previousSelection = uiView.selectedRange
            uiView.text = text
            if previousSelection.location <= (text as NSString).length {
                uiView.selectedRange = previousSelection
            }
        }
        if uiView.selectedRange != selectedRange, selectedRange.location != NSNotFound {
            let length = (uiView.text as NSString).length
            let clamped = NSRange(
                location: min(selectedRange.location, length),
                length: min(selectedRange.length, max(0, length - selectedRange.location))
            )
            uiView.selectedRange = clamped
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: UITextView?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            self.textView = textView
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            self.textView = textView
            parent.selectedRange = textView.selectedRange
        }
    }
}
