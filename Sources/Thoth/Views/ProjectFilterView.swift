import SwiftUI

/// Project filter in the popover header: a chip that opens a menu of the history's projects.
/// It stays on screen whatever the tab, so filtered numbers are never mistaken for the total;
/// a selected project shows with an accent dot and border.
struct ProjectFilterView: View {
    let projects: [String]
    let selected: String?
    let onSelect: (String?) -> Void

    static let allProjectsTitle = "All projects"

    var body: some View {
        Menu {
            Picker("Project", selection: Binding(get: { selected }, set: onSelect)) {
                Text(Self.allProjectsTitle).tag(String?.none)
                if !choices.isEmpty {
                    Divider()
                }
                ForEach(choices, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            chip
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(selected.map { "Showing only \($0). Every number in the popover is filtered." }
              ?? "Showing every project. Pick one to filter every number in the popover.")
        .accessibilityLabel("Project filter")
        .accessibilityValue(selected ?? Self.allProjectsTitle)
    }

    /// `name` cut in the middle past `Theme.Size.filterLabelMaxCharacters` (the chip's font is
    /// monospaced, so this bounds its width); the menu shows the full name.
    static func shortened(_ name: String) -> String {
        let limit = Theme.Size.filterLabelMaxCharacters
        guard name.count > limit else { return name }
        let head = (limit - 1) / 2
        return String(name.prefix(head)) + "…" + String(name.suffix(limit - 1 - head))
    }

    /// The history's projects, plus the selected one while no read has listed it yet.
    private var choices: [String] {
        if let selected, !projects.contains(selected) { return [selected] + projects }
        return projects
    }

    private var chip: some View {
        let isFiltered = selected != nil
        return HStack(spacing: Theme.Spacing.xs + 1) {
            if isFiltered {
                Circle()
                    .fill(Theme.Palette.accent)
                    .frame(width: Theme.Size.dot, height: Theme.Size.dot)
            }
            Text(Self.shortened(selected ?? Self.allProjectsTitle).uppercased())
                .font(Theme.Font.captionNumber)
                .tracking(Theme.labelTracking / 2)
                .foregroundStyle(isFiltered ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(Theme.Font.chevron)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.sm + 2)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Capsule().fill(Theme.Palette.background))
        .overlay(Capsule().strokeBorder(isFiltered ? Theme.Palette.accent.opacity(0.6) : Theme.Palette.border,
                                        lineWidth: Theme.Size.hairline))
        .contentShape(Capsule())
    }
}
