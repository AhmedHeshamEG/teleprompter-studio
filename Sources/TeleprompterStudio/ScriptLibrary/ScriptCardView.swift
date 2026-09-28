import SwiftUI

struct ScriptCardView: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text(script.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)

            Text(script.firstLine.isEmpty ? "Empty script" : script.firstLine)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            ScriptMeta(script: script)
        }
        .padding(Theme.spacingM)
        .frame(height: 156, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
    }
}

struct ScriptRowView: View {
    let script: Script

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            VStack(alignment: .leading, spacing: 3) {
                Text(script.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(script.firstLine.isEmpty ? "Empty script" : script.firstLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            ScriptMeta(script: script, isStacked: true)
        }
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium, style: .continuous))
    }
}

/// Words, read time, and — for notebook scripts — how many pictures are in it.
private struct ScriptMeta: View {
    let script: Script
    var isStacked = false

    var body: some View {
        let pictures = ScriptImageMarkup.matches(in: script.bodyMarkdown).count
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 2))
            : AnyLayout(HStackLayout(spacing: Theme.spacingM))
        layout {
            Label("\(script.wordCount)", systemImage: "textformat")
            if pictures > 0 {
                Label("\(pictures)", systemImage: "photo")
            }
            if !isStacked { Spacer(minLength: 0) }
            Label(script.estimatedReadSeconds.asTimecode, systemImage: "clock")
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption)
        .foregroundStyle(Theme.textTertiary)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title.monospacedDigit()
        }
    }
}
