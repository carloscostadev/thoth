import SwiftUI
import AppKit

/// Project filter in the popover header: a chip that opens a menu of the history's projects.
/// It stays on screen whatever the tab, so filtered numbers are never mistaken for the total;
/// a selected project shows with an accent dot and border.
struct ProjectFilterView: View {
    /// Highest all-time cost first, temporary folders last (`ProjectGroup.menuOrder`).
    let projects: [(name: String, cost: Double)]
    let selected: String?
    let onSelect: (String?) -> Void

    static let allProjectsTitle = "All projects"

    @State private var anchor = ProjectFilterMenuAnchor.Holder()

    var body: some View {
        Button {
            anchor.view?.popUpMenu()
        } label: {
            chip
        }
        .buttonStyle(.plain)
        .background(ProjectFilterMenuAnchor.Representable(holder: anchor) {
            ProjectFilterMenu(entries: entries, selected: selected, onSelect: onSelect)
        })
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

    /// The history's projects, plus the selected one (without a cost) while no read has listed it yet.
    private var entries: [ProjectFilterMenu.Entry] {
        let listed = projects.map { ProjectFilterMenu.Entry(name: $0.name, cost: $0.cost) }
        if let selected, !projects.contains(where: { $0.name == selected }) {
            return [ProjectFilterMenu.Entry(name: selected, cost: nil)] + listed
        }
        return listed
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

/// The picker's menu, an `NSMenu` so each project's estimated cost can sit right-aligned beside
/// its name: "All projects", then the first `directLimit` entries, the rest under "More".
/// Temporary folders, last in the order, end the menu (or "More"), after a separator.
final class ProjectFilterMenu: NSObject {
    struct Entry: Equatable {
        let name: String
        /// All-time estimated cost; nil for a remembered project no read has listed yet.
        let cost: Double?
    }

    static let directLimit = 10
    static let moreTitle = "More"

    let menu = NSMenu()
    private let onSelect: (String?) -> Void

    init(entries: [Entry], selected: String?, onSelect: @escaping (String?) -> Void) {
        self.onSelect = onSelect
        super.init()
        menu.autoenablesItems = false
        let (direct, more) = Self.split(entries)
        let costColumn = Self.costColumn(for: entries)

        menu.addItem(item(title: ProjectFilterView.allProjectsTitle, project: nil, cost: nil,
                          column: costColumn, selected: selected == nil))
        if !direct.isEmpty { menu.addItem(.separator()) }
        add(direct, to: menu, selected: selected, column: costColumn)
        if !more.isEmpty {
            let submenu = NSMenu(title: Self.moreTitle)
            submenu.autoenablesItems = false
            add(more, to: submenu, selected: selected, column: costColumn)
            let moreItem = NSMenuItem(title: Self.moreTitle, action: nil, keyEquivalent: "")
            moreItem.submenu = submenu
            // A dash when the selected project is inside.
            moreItem.state = more.contains { $0.name == selected } ? .mixed : .off
            menu.addItem(moreItem)
        }
    }

    /// The first `directLimit` entries, then the rest.
    static func split(_ entries: [Entry]) -> (direct: [Entry], more: [Entry]) {
        (Array(entries.prefix(directLimit)), Array(entries.dropFirst(directLimit)))
    }

    /// "≈ $12.34": every cost in Thoth is an estimate from public API prices.
    static func costText(_ cost: Double) -> String {
        "≈ " + String(format: "$%.2f", cost)
    }

    private func add(_ entries: [Entry], to menu: NSMenu, selected: String?, column: CGFloat) {
        for entry in entries {
            if entry.name == ProjectGroup.temporaryFoldersName, menu.numberOfItems > 0,
               menu.items.last?.isSeparatorItem == false {
                menu.addItem(.separator())
            }
            menu.addItem(item(title: entry.name, project: entry.name, cost: entry.cost,
                              column: column, selected: entry.name == selected))
        }
    }

    private func item(title: String, project: String?, cost: Double?, column: CGFloat, selected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = project
        item.state = selected ? .on : .off
        if let cost {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: column)]
            let text = NSMutableAttributedString(string: title + "\t", attributes: [
                .font: Self.nameFont, .paragraphStyle: style,
            ])
            text.append(NSAttributedString(string: Self.costText(cost), attributes: [
                .font: Self.costFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
            ]))
            item.attributedTitle = text
        }
        return item
    }

    @objc private func pick(_ item: NSMenuItem) {
        onSelect(item.representedObject as? String)
    }

    private static let nameFont = NSFont.menuFont(ofSize: 0)
    private static let costFont = NSFont.monospacedDigitSystemFont(ofSize: nameFont.pointSize, weight: .regular)

    /// Right edge of the cost column: past the longest name and the widest cost.
    private static func costColumn(for entries: [Entry]) -> CGFloat {
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let names = entries.map { width($0.name, nameFont) } + [width(ProjectFilterView.allProjectsTitle, nameFont)]
        let costs = entries.compactMap(\.cost).map { width(costText($0), costFont) }
        return (names.max() ?? 0) + Theme.Spacing.xxl + (costs.max() ?? 0)
    }
}

/// The AppKit view the menu opens under, behind the chip.
final class ProjectFilterMenuAnchor: NSView {
    final class Holder {
        weak var view: ProjectFilterMenuAnchor?
    }

    struct Representable: NSViewRepresentable {
        let holder: Holder
        let makeMenu: () -> ProjectFilterMenu

        func makeNSView(context: Context) -> ProjectFilterMenuAnchor {
            let view = ProjectFilterMenuAnchor()
            holder.view = view
            return view
        }

        func updateNSView(_ view: ProjectFilterMenuAnchor, context: Context) {
            holder.view = view
            view.makeMenu = makeMenu
        }
    }

    var makeMenu: (() -> ProjectFilterMenu)?
    /// The open menu's items target it, and `NSMenuItem.target` is weak.
    private var current: ProjectFilterMenu?

    func popUpMenu() {
        guard let menu = makeMenu?() else { return }
        current = menu
        let gap = Theme.Spacing.xs
        menu.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + gap : -gap), in: self)
    }
}
