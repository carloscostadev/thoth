import SwiftUI

struct ProjectsTabView: View {
    let service: ClaudeDataService

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ProjectRankingView(ranking: service.projectRanking)
                .themeCard()

            HeatmapView(matrix: service.heatmap, maxValue: service.heatmapMax)
                .themeCard()
        }
    }
}

struct ProjectRankingView: View {
    let ranking: [(name: String, cost: Double)]

    private var total: Double {
        ranking.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader("Top Projetos · All Time")

            if ranking.isEmpty {
                Text("Sem dados.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                ForEach(Array(ranking.prefix(8).enumerated()), id: \.offset) { index, item in
                    projectRow(rank: index + 1, name: item.name, cost: item.cost)
                }
            }
        }
    }

    private func projectRow(rank: Int, name: String, cost: Double) -> some View {
        let pct = total > 0 ? cost / total : 0
        return HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Text(String(format: "%02d", rank))
                .font(Theme.Font.captionNumber)
                .foregroundStyle(rank == 1 ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Text(name)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(String(format: "%.0f%%", pct * 100))
                        .font(Theme.Font.captionNumber)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(String(format: "$%.2f", cost))
                        .font(Theme.Font.number)
                        .foregroundStyle(Theme.Palette.cost)
                }
                ThemeBar(fraction: pct,
                         color: rank == 1 ? Theme.Palette.textPrimary : Theme.Palette.textTertiary,
                         height: Theme.Size.thinBarHeight)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

struct HeatmapView: View {
    let matrix: [[Double]] // [weekday 0..6][hour 0..23]
    let maxValue: Double

    private let weekdays = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Heatmap · hora × dia") {
                legend
            }

            GeometryReader { geo in
                let labelWidth: CGFloat = 14
                let gap: CGFloat = 2
                let cellW = max(4, (geo.size.width - labelWidth - gap * 24) / 24)
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: gap) {
                            Text(weekdays[day])
                                .font(Theme.Font.microNumber)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: labelWidth, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in
                                let v = matrix[day][hour]
                                let intensity = maxValue > 0 ? v / maxValue : 0
                                RoundedRectangle(cornerRadius: Theme.Radius.bar)
                                    .fill(Theme.heat(intensity))
                                    .frame(width: cellW, height: cellW)
                            }
                        }
                    }
                    HStack(spacing: gap) {
                        Spacer().frame(width: labelWidth)
                        ForEach([0, 6, 12, 18], id: \.self) { hour in
                            Text("\(hour)h")
                                .font(Theme.Font.microNumber)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: cellW * 6 + gap * 5, alignment: .leading)
                        }
                    }
                }
            }
            .frame(height: 7 * 14 + 14)
        }
    }

    private var legend: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text("LESS")
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { step in
                RoundedRectangle(cornerRadius: Theme.Radius.bar)
                    .fill(Theme.heat(step))
                    .frame(width: 8, height: 8)
            }
            Text("MORE")
        }
        .font(Theme.Font.microNumber)
        .foregroundStyle(Theme.Palette.textTertiary)
    }
}
