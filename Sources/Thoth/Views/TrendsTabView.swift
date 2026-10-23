import SwiftUI

struct TrendsTabView: View {
    let service: ClaudeDataService

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            DailyCostChartView(series: service.dailyCostSeries)
                .themeCard()

            HStack(spacing: Theme.Spacing.sm) {
                MetricCardView(
                    title: "Month Projection",
                    value: String(format: "$%.2f", service.projectedMonthCost),
                    subtitle: "MTD + 7-day avg"
                )
                MetricCardView(
                    title: "Cost Saved",
                    value: String(format: "%.0f%%", savedPct(service) * 100),
                    subtitle: "cache / (cache + paid)"
                )
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader(title: "Cache Savings") {
                    ThemeChip(text: "All Time", dot: Theme.Palette.positive)
                }
                Text(String(format: "$%.2f", service.cacheSavings))
                    .font(Theme.Font.metric)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("vs. pricing without cache")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .themeCard()
        }
    }
}

private func savedPct(_ service: ClaudeDataService) -> Double {
    let denom = service.cacheSavings + service.allTimeCost
    return denom > 0 ? service.cacheSavings / denom : 0
}

struct DailyCostChartView: View {
    let series: [(date: Date, cost: Double, tokens: Int)]
    @State private var selectedIndex: Int? = nil

    private var maxCost: Double {
        max(series.map { $0.cost }.max() ?? 0, 1)
    }

    private var total: Double {
        series.map { $0.cost }.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Daily Cost · 30d") {
                Text(String(format: "Σ $%.2f", total))
                    .font(Theme.Font.captionNumber)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            Group {
                if let idx = selectedIndex, idx < series.count {
                    let point = series[idx]
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(String(format: "$%.2f", point.cost))
                            .font(Theme.Font.number)
                            .foregroundStyle(Theme.Palette.cost)
                        Text("\(longDate(point.date)) · \(ClaudeDataService.formatTokens(point.tokens)) tok")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                } else {
                    Text("Click a bar to see the day")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .frame(height: 16, alignment: .leading)

            GeometryReader { geo in
                let gap: CGFloat = 2
                let barWidth = max(2, (geo.size.width - CGFloat(series.count - 1) * gap) / CGFloat(max(series.count, 1)))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(series.enumerated()), id: \.offset) { index, point in
                        let h = CGFloat(point.cost / maxCost) * geo.size.height
                        let isSelected = selectedIndex == index
                        Button {
                            selectedIndex = (selectedIndex == index) ? nil : index
                        } label: {
                            RoundedRectangle(cornerRadius: Theme.Radius.bar)
                                .fill(barColor(cost: point.cost, isSelected: isSelected))
                                .frame(width: barWidth, height: max(h, 2))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(longDate(point.date)) — \(String(format: "$%.2f", point.cost)) — \(ClaudeDataService.formatTokens(point.tokens)) tok")
                    }
                }
            }
            .frame(height: Theme.Size.chartHeight)

            HStack {
                Text(shortDate(series.first?.date))
                Spacer()
                Text(shortDate(series.last?.date))
            }
            .font(Theme.Font.micro)
            .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func barColor(cost: Double, isSelected: Bool) -> Color {
        Theme.chartBar(hasValue: cost > 0, isSelected: isSelected, isDimmed: selectedIndex != nil)
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    private func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }
}

struct MetricCardView: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ThemeLabel(title)
            Text(value)
                .font(Theme.Font.metric)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(subtitle)
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .themeCard()
    }
}
