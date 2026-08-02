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
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Label("\(script.wordCount)", systemImage: "textformat")
                Spacer()
                Label(script.estimatedReadSeconds.asTimecode, systemImage: "clock")
            }
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.spacingM)
        .frame(height: 150, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

struct ScriptRowView: View {
    let script: Script

    var body: some View {
        HStack(spacing: Theme.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(script.firstLine.isEmpty ? "Empty script" : script.firstLine)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(script.wordCount) words")
                Text(script.estimatedReadSeconds.asTimecode)
            }
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.spacingM)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
    }
}
