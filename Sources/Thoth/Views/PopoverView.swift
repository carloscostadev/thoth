import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case trends = "Trends"
    case projects = "Projects"
    var id: String { rawValue }
}

struct PopoverView: View {
    @State var service: ClaudeDataService
    @State private var selectedTab: PopoverTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            StatusHeaderView(
                activityState: service.activityState,
                burnRate: service.formattedBurnRate,
                isConnected: service.isConnected,
                todayCost: service.formattedTodayCost,
                todayTokens: service.todayTokens,
                todayCalls: service.todayCalls,
                dataStatus: service.dataStatus,
                projects: service.availableProjects,
                selectedProject: service.selectedGroup,
                onSelectProject: { service.applyFilter($0) }
            )
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.md)

            TabBarView(selected: $selectedTab)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.sm)

            ScrollView {
                VStack(spacing: Theme.Spacing.sm) {
                    // Without a read there are no figures: the lists would only hold zeros that
                    // look real, so none of them is shown.
                    if let message = service.dataStatus.unavailableMessage {
                        DataUnavailableView(message: message)
                    } else {
                        switch selectedTab {
                        case .overview:
                            OverviewTabView(service: service)
                        case .trends:
                            TrendsTabView(service: service)
                        case .projects:
                            ProjectsTabView(service: service)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.md)
            }
            .frame(height: Theme.Size.contentHeight)

            ThemeDivider()

            FooterView(lastRead: service.lastSuccessfulRead)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
        }
        .frame(width: Theme.Size.popoverWidth)
        .background(Theme.Palette.background)
    }
}

struct TabBarView: View {
    @Binding var selected: PopoverTab
    @Namespace private var selection

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ForEach(PopoverTab.allCases) { tab in
                let isSelected = selected == tab
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selected = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(Theme.Font.tab)
                        .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.xs + Theme.Spacing.xxs)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.Palette.surfaceRaised)
                                    .matchedGeometryEffect(id: "tab", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Spacing.xs)
        .background(Capsule().fill(Theme.Palette.surface))
        .overlay(Capsule().strokeBorder(Theme.Palette.border, lineWidth: Theme.Size.hairline))
    }
}

struct FooterView: View {
    let lastRead: Date?

    var body: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { LaunchAtLogin.isEnabled = $0 }
            ))
            .toggleStyle(.checkbox)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(DataStatus.updatedText(lastRead: lastRead, now: context.date))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .help(lastRead.map { "Last successful read of ~/.claude/projects: \($0.formatted(date: .abbreviated, time: .standard))" }
                  ?? "~/.claude/projects hasn't been read yet")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                ThemeChip(text: "Quit")
            }
            .buttonStyle(.plain)
        }
    }
}

/// Stands in for every tab while the history hasn't been read.
struct DataUnavailableView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader("No figures")
            Text(DataStatus.placeholder)
                .font(Theme.Font.metric)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .themeCard()
        .accessibilityElement(children: .combine)
    }
}

struct OverviewTabView: View {
    let service: ClaudeDataService

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if !service.todayActivity.sortedEntries.isEmpty {
                ActivitySectionView(entries: service.todayActivity.sortedEntries)
                    .themeCard()
            }

            SummaryRowsView(
                todayCost: service.formattedTodayCost,
                todayCalls: service.todayCalls,
                todayTokens: service.todayTokens,
                weekCost: service.formattedWeekCost,
                weekCalls: service.weekCalls,
                weekTokens: service.weekTokens,
                fifteenDaysCost: service.formattedFifteenDaysCost,
                fifteenDaysCalls: service.fifteenDaysCalls,
                fifteenDaysTokens: service.fifteenDaysTokens,
                monthCost: service.formattedMonthCost,
                monthCalls: service.monthCalls,
                monthTokens: service.monthTokens,
                allTimeCost: service.formattedAllTimeCost,
                allTimeCalls: service.allTimeCalls,
                allTimeTokens: service.allTimeTokens
            )
            .themeCard()

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                SectionHeader("Models · All Time")
                ModelsTabView(entries: service.modelUsage.entries)
            }
            .themeCard()
        }
    }
}
