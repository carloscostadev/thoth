import SwiftUI

struct StatusHeaderView: View {
    let activityState: ActivityState
    let burnRate: String
    let isConnected: Bool
    let todayCost: String
    let todayTokens: Int
    let todayCalls: Int

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "gauge.open.with.lines.needle.33percent")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(AppInstance.name)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                ThemeChip(
                    text: isConnected ? "Connected" : "No Sessions",
                    dot: Theme.connectionColor(isConnected)
                )
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .firstTextBaseline) {
                    ThemeLabel("Today · Cost")
                    Spacer()
                    ThemeChip(
                        text: activityState.rawValue,
                        dot: Theme.color(for: activityState),
                        textColor: Theme.Palette.textPrimary
                    )
                    .help(activityState.description)
                }

                Text(todayCost)
                    .font(Theme.Font.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())

                HStack(spacing: 0) {
                    metric(label: "Tokens", value: ClaudeDataService.formatTokens(todayTokens))
                    metricDivider
                    metric(label: "Calls", value: ClaudeDataService.formatCalls(todayCalls))
                    metricDivider
                    metric(label: "Burn", value: burnRate)
                }
            }
            .themeCard(.hero, padding: Theme.Spacing.xl)
        }
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(width: Theme.Size.hairline, height: Theme.Spacing.xxl)
            .padding(.horizontal, Theme.Spacing.md)
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ThemeLabel(label)
            Text(value)
                .font(Theme.Font.number)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
