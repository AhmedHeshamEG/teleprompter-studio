import SwiftUI

struct EditorToolbar: View {
    let apply: (@escaping (String, NSRange) -> MarkdownFormatter.Result) -> Void
    /// Opens the photo picker; the editor owns the picker and does the inserting.
    var insertPicture: () -> Void = {}

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingXS) {
                // The notebook tools first: they're what makes a script more than text.
                Button(action: insertPicture) {
                    toolGlyph("photo")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert Picture")

                // A cue is a line you *see* but don't *say* ("hold up the book", "look at camera
                // two"): shown smaller and in the script's accent colour on the prompter.
                toolButton("text.bubble", label: "Cue Line") { text, range in
                    MarkdownFormatter.toggleLinePrefix(text: text, range: range, token: "> ")
                }

                divider

                toolButton("bold", label: "Bold") { text, range in
                    MarkdownFormatter.toggleWrap(text: text, range: range, prefix: "**", suffix: "**")
                }
                toolButton("italic", label: "Italic") { text, range in
                    MarkdownFormatter.toggleWrap(text: text, range: range, prefix: "*", suffix: "*")
                }
                toolButton("underline", label: "Underline") { text, range in
                    MarkdownFormatter.toggleWrap(text: text, range: range, prefix: "<u>", suffix: "</u>")
                }

                divider

                Menu {
                    Button("Heading 1") { applyHeading("# ") }
                    Button("Heading 2") { applyHeading("## ") }
                    Button("Heading 3") { applyHeading("### ") }
                } label: {
                    toolGlyph("textformat.size")
                }

                Menu {
                    Button("Left") { setAlignment("left") }
                    Button("Center") { setAlignment("center") }
                    Button("Right") { setAlignment("right") }
                } label: {
                    toolGlyph("text.alignleft")
                }

                divider

                toolButton("x.squareroot", label: "Inline Math") { text, range in
                    MarkdownFormatter.insertInlineMath(text: text, range: range)
                }
                toolButton("function", label: "Math Block") { text, range in
                    MarkdownFormatter.insertBlockMath(text: text, range: range)
                }
            }
            .padding(.horizontal, Theme.spacingS)
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 0.5, height: 20)
            .padding(.horizontal, Theme.spacingXS)
    }

    private func toolGlyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
            .contentShape(Rectangle())
    }

    private func toolButton(
        _ systemImage: String,
        label: String,
        transform: @escaping (String, NSRange) -> MarkdownFormatter.Result
    ) -> some View {
        Button {
            apply(transform)
        } label: {
            toolGlyph(systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func applyHeading(_ token: String) {
        apply { text, range in
            MarkdownFormatter.toggleLinePrefix(text: text, range: range, token: token)
        }
    }

    private func setAlignment(_ alignment: String) {
        apply { text, range in
            MarkdownFormatter.setAlignment(text: text, range: range, alignment: alignment)
        }
    }
}
