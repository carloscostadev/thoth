import SwiftUI

struct SessionsTabView: View {
    let sessions: [SessionData]

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if sessions.isEmpty {
                Text("No active sessions")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.xl)
            } else {
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: SessionData) -> some View {
        HStack {
            Circle()
                .fill(Theme.Palette.positive)
                .frame(width: Theme.Size.dot, height: Theme.Size.dot)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(session.projectName)
                    .font(Theme.Font.bodyEmphasis)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(session.projectGroup)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text(formatDuration(session.duration))
                    .font(Theme.Font.number)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("PID \(session.pid)")
                    .font(Theme.Font.captionNumber)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .themeCard(padding: Theme.Spacing.sm + Theme.Spacing.xxs)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}
