import SwiftUI

struct ActivitySectionView: View {
    let entries: [ActivityEntry]

    private var maxCost: Double {
        entries.map(\.cost).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader("Activity · Today")

            ForEach(entries) { entry in
                activityRow(entry)
            }
        }
    }

    private func activityRow(_ entry: ActivityEntry) -> some View {
        let color = Theme.color(for: entry.category)
        let fraction = maxCost > 0 ? entry.cost / maxCost : 0

        return HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(color)
                .frame(width: Theme.Size.dot, height: Theme.Size.dot)

            Text(entry.category.rawValue)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 92, alignment: .leading)

            ThemeBar(fraction: fraction, color: color)

            Text(String(format: "$%.2f", entry.cost))
                .font(Theme.Font.number)
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 64, alignment: .trailing)

            Text("\(entry.turns) turns")
                .font(Theme.Font.captionNumber)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 20)
    }
}
