import SwiftUI

struct EditorToolbar: View {
    let apply: (@escaping (String, NSRange) -> MarkdownFormatter.Result) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingS) {
                toolButton("bold") { text, range in
                    MarkdownFormatter.toggleWrap(text: text, range: range, prefix: "**", suffix: "**")
                }
                toolButton("italic") { text, range in
                    MarkdownFormatter.toggleWrap(text: text, range: range, prefix: "*", suffix: "*")
                }
                toolButton("underline") { text, range in
                    MarkdownFormatter.toggleWrap(text: text, range: range, prefix: "<u>", suffix: "</u>")
                }

                Divider().frame(height: 24)

                Menu {
                    Button("Heading 1") { applyHeading("# ") }
                    Button("Heading 2") { applyHeading("## ") }
                    Button("Heading 3") { applyHeading("### ") }
                } label: {
                    Image(systemName: "textformat.size")
                        .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
                }

                Menu {
                    Button("Left") { setAlignment("left") }
                    Button("Center") { setAlignment("center") }
                    Button("Right") { setAlignment("right") }
                } label: {
                    Image(systemName: "text.alignleft")
                        .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
                }

                Divider().frame(height: 24)

                toolButton("x.squareroot") { text, range in
                    MarkdownFormatter.insertInlineMath(text: text, range: range)
                }
                Button {
                    apply { text, range in
                        MarkdownFormatter.insertBlockMath(text: text, range: range)
                    }
                } label: {
                    Image(systemName: "function")
                        .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.spacingM)
        }
        .frame(height: 52)
        .background(Theme.surface)
    }

    private func toolButton(_ systemImage: String, transform: @escaping (String, NSRange) -> MarkdownFormatter.Result) -> some View {
        Button {
            apply(transform)
        } label: {
            Image(systemName: systemImage)
                .frame(width: Theme.minControlSizeCompact, height: Theme.minControlSizeCompact)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textPrimary)
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
