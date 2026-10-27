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
            if entries.contains(where: \.hasApproximatePricing) {
                Text("≈ Approximate: priced at the rates of the closest known version of the family.")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if entries.contains(where: \.hasNoKnownPrice) {
                Text("? No known price: counted in tokens and calls, left out of the cost totals.")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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
                if let note = entry.pricingNote {
                    Text(entry.hasNoKnownPrice ? "?" : "≈")
                        .font(Theme.Font.bodyEmphasis)
                        .foregroundStyle(Theme.Palette.caution)
                        .help(note)
                        .accessibilityLabel(note)
                }
                Spacer()
                Text(String(format: "%.0f%%", percentage))
                    .font(Theme.Font.captionNumber)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(String(format: "$%.2f", entry.totalCost))
                    .font(Theme.Font.number)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ThemeBar(fraction: percentage / 100, color: color)

            Text(detail(entry))
                .font(Theme.Font.captionNumber)
                .foregroundStyle(Theme.Palette.textTertiary)
                .help(entry.pricingNote ?? "")
        }
    }

    private func detail(_ entry: ModelUsageEntry) -> String {
        let base = "\(formatTokens(entry.totalTokens)) tokens · \(entry.sessionCount) sessions"
        if entry.hasNoKnownPrice { return base + " · no known price" }
        guard let match = entry.pricingMatch, !match.isExact else { return base }
        return base + " · ≈ \(match.referenceName) rates"
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
