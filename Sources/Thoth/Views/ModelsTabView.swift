import SwiftUI

struct ModelsTabView: View {
    let entries: [ModelUsageEntry]

    private var totalCost: Double {
        entries.reduce(0) { $0 + $1.totalCost }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ForEach(entries.sorted(by: { $0.totalCost > $1.totalCost })) { entry in
                modelRow(entry)
            }
        }
    }

    private func modelRow(_ entry: ModelUsageEntry) -> some View {
        let percentage = totalCost > 0 ? entry.totalCost / totalCost * 100 : 0
        let color = Theme.color(for: entry.family)

        return VStack(alignment: .leading, spacing: Theme.Spacing.xs + 1) {
            HStack(spacing: Theme.Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: Theme.Size.dot, height: Theme.Size.dot)
                Text(entry.displayName)
                    .font(Theme.Font.bodyEmphasis)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(String(format: "%.0f%%", percentage))
                    .font(Theme.Font.captionNumber)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(String(format: "$%.2f", entry.totalCost))
                    .font(Theme.Font.number)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ThemeBar(fraction: percentage / 100, color: color)

            Text("\(formatTokens(entry.totalTokens)) tokens · \(entry.sessionCount) sessions")
                .font(Theme.Font.captionNumber)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
