import SwiftUI

struct SummaryRowsView: View {
    let todayCost: String
    let todayCalls: Int
    let todayTokens: Int
    let weekCost: String
    let weekCalls: Int
    let weekTokens: Int
    let fifteenDaysCost: String
    let fifteenDaysCalls: Int
    let fifteenDaysTokens: Int
    let monthCost: String
    let monthCalls: Int
    let monthTokens: Int
    let allTimeCost: String
    let allTimeCalls: Int
    let allTimeTokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            SectionHeader("Periods")
                .padding(.bottom, Theme.Spacing.xxs)
            summaryRow(label: "Today", cost: todayCost, calls: todayCalls, tokens: todayTokens)
            ThemeDivider()
            summaryRow(label: "7 Days", cost: weekCost, calls: weekCalls, tokens: weekTokens)
            ThemeDivider()
            summaryRow(label: "15 Days", cost: fifteenDaysCost, calls: fifteenDaysCalls, tokens: fifteenDaysTokens)
            ThemeDivider()
            summaryRow(label: "30 Days", cost: monthCost, calls: monthCalls, tokens: monthTokens)
            ThemeDivider()
            summaryRow(label: "All Time", cost: allTimeCost, calls: allTimeCalls, tokens: allTimeTokens)
        }
    }

    private func summaryRow(label: String, cost: String, calls: Int, tokens: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)

            Spacer()

            Text("\(ClaudeDataService.formatTokens(tokens)) tok · \(ClaudeDataService.formatCalls(calls)) calls")
                .font(Theme.Font.captionNumber)
                .foregroundStyle(Theme.Palette.textTertiary)

            Text(cost)
                .font(Theme.Font.number)
                .foregroundStyle(Theme.Palette.cost)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, Theme.Spacing.xs + 1)
        .contentShape(Rectangle())
    }
}
