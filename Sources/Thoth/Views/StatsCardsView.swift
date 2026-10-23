import SwiftUI

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ThemeLabel(title)
            Text(value)
                .font(Theme.Font.number)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .themeCard(padding: Theme.Spacing.md)
    }
}

struct StatsCardsView: View {
    let burnRate: String
    let totalTokens: String
    let totalCost: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            StatCard(title: "Burn Rate", value: burnRate)
            StatCard(title: "Tokens", value: totalTokens)
            StatCard(title: "Cost", value: totalCost)
        }
    }
}
