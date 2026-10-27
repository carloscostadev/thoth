import SwiftUI

struct ActivitySectionView: View {
    let entries: [ActivityEntry]

    private var maxCost: Double {
        entries.map(\.cost).max() ?? 1
    }

    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Activity · Today") {
                InfoButton(isPresented: $showsExplanation,
                           label: "How activity categories are inferred",
                           help: ActivityCategory.explanation) {
                    ActivityExplanationView()
                }
            }

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
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 58, alignment: .trailing)
        }
        .frame(height: 20)
    }
}

/// Popover content: how turns are classified, category by category.
struct ActivityExplanationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ThemeLabel("How activity is inferred")
            Text(ActivityCategory.explanation)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(ActivityCategory.classificationOrder) { category in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Circle()
                            .fill(Theme.color(for: category))
                            .frame(width: Theme.Size.dot, height: Theme.Size.dot)
                        Text(category.rawValue)
                            .font(Theme.Font.bodyEmphasis)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .frame(width: 92, alignment: .leading)
                        Text(category.rule)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 340, alignment: .leading)
        .background(Theme.Palette.background)
    }
}
