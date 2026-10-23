import SwiftUI

struct ModelsTabView: View {
    let entries: [ModelUsageEntry]

    private var totalCost: Double {
        entries.reduce(0) { $0 + $1.totalCost }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(entries.sorted(by: { $0.totalCost > $1.totalCost })) { entry in
                modelRow(entry)
            }
        }
        .padding(.horizontal, 16)
    }

    private func modelRow(_ entry: ModelUsageEntry) -> some View {
        let percentage = totalCost > 0 ? entry.totalCost / totalCost * 100 : 0
        let color = modelColor(entry.family)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(entry.displayName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "$%.2f", entry.totalCost))
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundStyle(.white)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.1))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * min(percentage / 100, 1.0), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(formatTokens(entry.totalTokens)) tokens · \(entry.sessionCount) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", percentage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func modelColor(_ family: ModelFamily?) -> Color {
        switch family {
        case .opus: return .pink
        case .sonnet: return .blue
        case .haiku: return .green
        case .fable, .mythos: return .purple
        case nil: return .gray
        }
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
