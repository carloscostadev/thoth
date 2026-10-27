import SwiftUI

struct StatusHeaderView: View {
    let activityState: ActivityState
    let burnRate: String
    let isConnected: Bool
    let todayCost: String
    let todayTokens: Int
    let todayCalls: Int
    var dataStatus: DataStatus = .ready

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                ThothLockup(height: Theme.Size.headerMark)
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

                // No figures until the history has been read: "—", never a $0.00 that looks real.
                Text(dataStatus.display(todayCost))
                    .font(Theme.Font.hero)
                    .foregroundStyle(dataStatus.showsFigures ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                    .contentTransition(.numericText())

                HStack(spacing: 0) {
                    metric(label: "Tokens", value: dataStatus.display(ClaudeDataService.formatTokens(todayTokens)))
                    metricDivider
                    metric(label: "Calls", value: dataStatus.display(ClaudeDataService.formatCalls(todayCalls)))
                    metricDivider
                    metric(label: "Burn", value: dataStatus.display(burnRate))
                }
            }
            .themeCard(.hero, padding: Theme.Spacing.xl)

            if let notice = dataStatus.notice {
                DataStatusNotice(status: dataStatus, text: notice)
            }
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

/// One line under the hero card when the history isn't fully read: reading, missing,
/// unreadable or partly read.
struct DataStatusNotice: View {
    let status: DataStatus
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if case .loading = status {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: symbol)
                    .font(Theme.Font.icon)
                    .foregroundStyle(Theme.color(for: status) ?? Theme.Palette.textTertiary)
            }
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .strokeBorder(Theme.color(for: status)?.opacity(0.5) ?? Theme.Palette.border,
                              lineWidth: Theme.Size.hairline)
        )
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .noHistory: return "tray"
        case .inaccessible: return "lock"
        case .partial: return "exclamationmark.triangle"
        case .loading, .ready: return "checkmark.circle"
        }
    }
}
