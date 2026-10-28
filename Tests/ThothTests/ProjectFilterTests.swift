// Tests/ThothTests/ProjectFilterTests.swift
import AppKit
import Foundation
import Testing
@testable import Thoth

/// The project filter: every published number follows it, the choice is remembered and falls
/// back to all projects when the project is gone; and copies of a response shared by several
/// transcripts count in the same place whatever the read order. Synthetic histories only.
@MainActor
@Suite(.serialized)
struct ProjectFilterTests {
    private static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-4-6"]

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// A private defaults domain, so tests never touch the app's (or each other's) choice.
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "thoth-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func cost(_ r: SyntheticHistory.Request) -> Double {
        TokenUsage(inputTokens: r.input, outputTokens: r.output, cacheWriteTokens: r.cacheWrite,
                   cacheReadTokens: r.cacheRead, cacheWrite1hTokens: r.cacheWrite1h).cost(for: r.model)
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 * max(abs(a), abs(b), 1) }

    /// Requests of the files whose cwd is in group `name` ("…/Documents/<name>/…").
    private func requests(of history: SyntheticHistory, group name: String, perFile: Int) -> [SyntheticHistory.Request] {
        history.files.enumerated()
            .filter { $0.element.cwd.contains("/Documents/\(name)/") }
            .flatMap { history.requests[($0.offset * perFile)..<(($0.offset + 1) * perFile)] }
    }

    private func select(_ group: String?, on service: ClaudeDataService) async {
        service.applyFilter(group)
        service.waitForBackgroundWork()
        await drainMainQueue()
    }

    // MARK: - Filtered aggregation

    @Test func everyNumberFollowsTheSelectedProject() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 31)
        defer { history.remove() }
        let perFile = 30
        try history.generate(projects: 10, filesPerProject: 2, messagesPerFile: perFile, todayShare: 0.4)
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = ClaudeDataService(claudeDir: history.root.path, defaults: defaults)
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.selectedGroup == nil)
        #expect(Set(service.availableProjects.map(\.name)) == ["Group0", "Group1", "Group2", "Group3", "Group4"])
        // Highest cost first, the same order as the ranking.
        #expect(service.availableProjects.map(\.name) == service.projectRanking.map(\.name))
        let menuCosts = service.availableProjects
        let unfilteredCalls = service.allTimeCalls
        let unfilteredToday = service.todayCalls

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func since(_ days: Int) -> Date { cal.date(byAdding: .day, value: -(days - 1), to: today)! }

        var sumOfProjects = 0
        for group in service.availableProjects.map(\.name) {
            await select(group, on: service)
            let expected = requests(of: history, group: group, perFile: perFile)
            #expect(!expected.isEmpty)
            sumOfProjects += service.allTimeCalls

            // Periods.
            #expect(service.allTimeCalls == expected.count)
            #expect(service.allTimeTokens == expected.reduce(0) { $0 + $1.totalTokens })
            #expect(close(service.allTimeCost, expected.reduce(0) { $0 + cost($1) }))
            #expect(service.weekCalls == expected.filter { $0.date >= since(7) }.count)
            #expect(service.fifteenDaysCalls == expected.filter { $0.date >= since(15) }.count)
            #expect(service.monthCalls == expected.filter { $0.date >= since(30) }.count)
            #expect(service.monthTokens == expected.filter { $0.date >= since(30) }.reduce(0) { $0 + $1.totalTokens })

            // Today and its activity.
            let todays = expected.filter { $0.date >= today }
            #expect(service.todayCalls == todays.count)
            #expect(service.todayTokens == todays.reduce(0) { $0 + $1.totalTokens })
            #expect(close(service.todayCost, todays.reduce(0) { $0 + cost($1) }))
            var activity: [ActivityCategory: Int] = [:]
            for r in todays { activity[ActivityCategory.classify(tools: r.tools), default: 0] += 1 }
            #expect(service.todayActivity.entries.mapValues(\.turns) == activity)

            // Models.
            #expect(service.modelUsage.entries.reduce(0) { $0 + $1.totalTokens } == service.allTimeTokens)
            #expect(Set(service.modelUsage.entries.map(\.modelId)) == Set(expected.map(\.model)))

            // Trends and heatmap.
            let lastThirty = expected.filter { $0.date >= since(30) }.reduce(0.0) { $0 + cost($1) }
            #expect(close(service.dailyCostSeries.reduce(0) { $0 + $1.cost }, lastThirty))
            #expect(close(service.heatmap.joined().reduce(0, +), service.allTimeCost))

            // Ranking: only the project shown.
            #expect(service.projectRanking.map(\.name) == [group])
            #expect(service.dataStatus == .ready)
            // The picker still lists every project, with its all-time cost whatever the filter.
            #expect(service.availableProjects.map(\.name) == menuCosts.map(\.name))
            #expect(zip(service.availableProjects, menuCosts).allSatisfy { close($0.cost, $1.cost) })
            #expect(close(menuCosts.first { $0.name == group }!.cost, service.allTimeCost))
        }
        #expect(sumOfProjects == unfilteredCalls)

        // Back to all projects.
        await select(nil, on: service)
        #expect(service.allTimeCalls == unfilteredCalls)
        #expect(service.todayCalls == unfilteredToday)
        #expect(service.projectRanking.count == 5)
    }

    /// A project without use today shows a real zero (a complete read), not a missing figure.
    @Test func aProjectWithoutUseShowsARealZero() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 37)
        defer { history.remove() }
        try history.generate(projects: 1, filesPerProject: 2, messagesPerFile: 10, todayShare: 1,
                             cwds: ["/srv/synthetic/Documents/Busy/app"])
        try history.generate(projects: 1, filesPerProject: 2, messagesPerFile: 10, todayShare: 0,
                             cwds: ["/srv/synthetic/Documents/Quiet/app"])
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = ClaudeDataService(claudeDir: history.root.path, defaults: defaults)
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.todayCalls == 20)

        await select("Quiet", on: service)
        #expect(service.todayCalls == 0 && service.todayTokens == 0 && service.todayCost == 0)
        #expect(service.allTimeCalls == 20)
        #expect(service.dataStatus == .ready && service.dataStatus.showsFigures)
        #expect(service.dataStatus.display("$0.00") == "$0.00")
    }

    // MARK: - Persistence and fallback

    @Test func theChoiceIsRememberedAndFallsBackWhenTheProjectIsGone() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 41)
        defer { history.remove() }
        let perFile = 12
        try history.generate(projects: 3, filesPerProject: 2, messagesPerFile: perFile)
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ClaudeDataService(claudeDir: history.root.path, defaults: defaults)
        first.unifiedFullScan()
        await drainMainQueue()
        await select("Group1", on: first)
        #expect(defaults.string(forKey: ClaudeDataService.projectFilterKey) == "Group1")

        // Next launch: the filter is back before the first read, and the read follows it.
        let second = ClaudeDataService(claudeDir: history.root.path, defaults: defaults)
        #expect(second.selectedGroup == "Group1")
        second.unifiedFullScan()
        await drainMainQueue()
        #expect(second.selectedGroup == "Group1")
        #expect(second.allTimeCalls == requests(of: history, group: "Group1", perFile: perFile).count)

        // The project's transcripts go away: back to all projects, and that is remembered.
        for file in history.files where file.cwd.contains("/Group1/") {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        }
        second.unifiedFullScan()
        await drainMainQueue()
        #expect(second.selectedGroup == nil)
        #expect(defaults.string(forKey: ClaudeDataService.projectFilterKey) == nil)
        #expect(Set(second.availableProjects.map(\.name)) == ["Group0", "Group2"])
        #expect(second.allTimeCalls == 4 * perFile)
        #expect(second.projectRanking.count == 2)

        // A launch with a remembered project the history doesn't have also falls back.
        defaults.set("Gone", forKey: ClaudeDataService.projectFilterKey)
        let third = ClaudeDataService(claudeDir: history.root.path, defaults: defaults)
        #expect(third.selectedGroup == "Gone")
        third.unifiedFullScan()
        await drainMainQueue()
        #expect(third.selectedGroup == nil)
        #expect(defaults.string(forKey: ClaudeDataService.projectFilterKey) == nil)
        #expect(third.allTimeCalls == 4 * perFile)
    }

    /// A remembered project whose folder is now part of "Temporary folders" goes back to all
    /// projects; "Temporary folders" itself can be picked and remembered.
    @Test func aProjectNowInTemporaryFoldersFallsBack() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 43)
        defer { history.remove() }
        let perFile = 8
        try history.generate(projects: 3, filesPerProject: 2, messagesPerFile: perFile, cwds: [
            "/srv/synthetic/Documents/Acme/app",
            "/private/var/folders/xx/yy/T/snap-on-AbC123",
            "/private/tmp/claude-501/-srv-synthetic-Documents-Acme-app/441215ec-fa16-4c61-9222-046e26d390cf/scratchpad",
        ])
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // The name the picker showed for the first temporary folder before it was grouped.
        defaults.set("snap-on-AbC123", forKey: ClaudeDataService.projectFilterKey)

        let service = ClaudeDataService(claudeDir: history.root.path, defaults: defaults)
        #expect(service.selectedGroup == "snap-on-AbC123")
        service.unifiedFullScan()
        await drainMainQueue()
        #expect(service.selectedGroup == nil)
        #expect(defaults.string(forKey: ClaudeDataService.projectFilterKey) == nil)
        #expect(service.availableProjects.map(\.name) == ["Acme", ProjectGroup.temporaryFoldersName])
        #expect(service.allTimeCalls == 6 * perFile)

        await select(ProjectGroup.temporaryFoldersName, on: service)
        #expect(defaults.string(forKey: ClaudeDataService.projectFilterKey) == ProjectGroup.temporaryFoldersName)
        #expect(service.allTimeCalls == 4 * perFile)
        let next = ClaudeDataService(claudeDir: history.root.path, defaults: defaults)
        next.unifiedFullScan()
        await drainMainQueue()
        #expect(next.selectedGroup == ProjectGroup.temporaryFoldersName)
        #expect(next.allTimeCalls == 4 * perFile)
    }

    // MARK: - Picker menu

    /// Item names ("—" for a separator); a title with a cost reads "<name>\t≈ $<cost>".
    private func names(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : String($0.title.split(separator: "\t").first ?? "") }
    }

    @Test func theMenuShowsTenEntriesThenMoreWithTemporaryFoldersLast() {
        let temporary = ProjectGroup.temporaryFoldersName
        let entries = (0..<14).map { ProjectFilterMenu.Entry(name: "Project \($0)", cost: Double(100 - $0)) }
            + [ProjectFilterMenu.Entry(name: temporary, cost: 500)]
        var picked: [String?] = []
        // The items' target is the builder (a weak reference): keep it for the whole test.
        let built = ProjectFilterMenu(entries: entries, selected: "Project 12") { picked.append($0) }
        defer { withExtendedLifetime(built) {} }
        let menu = built.menu
        #expect(names(menu) == ["All projects", "—"] + (0..<10).map { "Project \($0)" } + ["More"])
        #expect(menu.items[0].state == .off)
        let more = try! #require(menu.items.last?.submenu)
        #expect(menu.items.last?.state == .mixed) // the selected project is inside
        #expect(names(more) == ["Project 10", "Project 11", "Project 12", "Project 13", "—", temporary])
        #expect(more.items[2].state == .on)
        // Costs sit beside the names, marked as estimates.
        #expect(menu.items[2].attributedTitle?.string == "Project 0\t≈ $100.00")
        #expect(more.items.last?.attributedTitle?.string == "\(temporary)\t≈ $500.00")
        // Picking an item reports its project; "All projects" reports nil.
        for item in [menu.items[0], more.items[3]] {
            _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        }
        #expect(picked == [nil, "Project 13"])
    }

    @Test func aShortMenuHasNoMore() {
        let temporary = ProjectGroup.temporaryFoldersName
        let entries = [ProjectFilterMenu.Entry(name: "Acme", cost: 2), ProjectFilterMenu.Entry(name: temporary, cost: 9)]
        let menu = ProjectFilterMenu(entries: entries, selected: nil) { _ in }.menu
        #expect(names(menu) == ["All projects", "—", "Acme", "—", temporary])
        #expect(menu.items[0].state == .on)
        #expect(menu.items.allSatisfy { $0.submenu == nil })
    }

    // MARK: - Copies shared by several projects

    private struct TwoProjects {
        static let alpha = "/srv/Documents/Alpha/app"
        static let beta = "/srv/Documents/Beta/app"
        let history: SyntheticHistory

        init() throws {
            history = try SyntheticHistory(models: [], seed: 1)
            for cwd in [Self.alpha, Self.beta] {
                try FileManager.default.createDirectory(at: dir(cwd), withIntermediateDirectories: true)
            }
        }

        func dir(_ cwd: String) -> URL { history.projectsDir.appendingPathComponent(SyntheticHistory.encode(cwd: cwd)) }

        static func line(_ id: String, cwd: String, output: Int, at date: Date) -> String {
            #"{"type":"assistant","cwd":"\#(cwd)","timestamp":"\#(SyntheticHistory.timestamp(date))","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":1000,"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
                + "\n"
        }

        func write(_ text: String, cwd: String, name: String) throws {
            let url = dir(cwd).appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    /// Calls per project, read with the project filter (heavy scan and today summary).
    private func callsByProject(_ service: ClaudeDataService) async -> [String: (all: Int, today: Int)] {
        var result: [String: (all: Int, today: Int)] = [:]
        for group in ["Alpha", "Beta"] {
            await select(group, on: service)
            result[group] = (service.allTimeCalls, service.todayCalls)
        }
        await select(nil, on: service)
        return result
    }

    /// Settable clock, to get past the today summary's one-minute walk interval.
    private final class TestClock: @unchecked Sendable {
        var now = Date()
    }

    /// A response copied into transcripts of two projects counts in the one where it appears
    /// first by timestamp, ties going to the path that sorts first, whichever is read first.
    @Test func copiesSharedByProjectsCountWhereTheyFirstAppear() async throws {
        let t = try TwoProjects()
        defer { t.history.remove() }
        typealias T = TwoProjects
        let now = Date().addingTimeInterval(-120)
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Beta is read first, alone: it counts its own response and the shared one.
        try t.write(T.line("msg_b", cwd: T.beta, output: 10, at: now)
                    + T.line("msg_tie", cwd: T.beta, output: 20, at: now)
                    + T.line("msg_early", cwd: T.beta, output: 30, at: now.addingTimeInterval(-60)), cwd: T.beta, name: "beta.jsonl")
        let clock = TestClock()
        let service = ClaudeDataService(claudeDir: t.history.root.path, now: { clock.now }, defaults: defaults)
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.allTimeCalls == 3 && service.todayCalls == 3)

        // Alpha turns up with the same timestamp for msg_tie (its path sorts first, so it takes
        // that one over) and a later copy of msg_early (Beta keeps it).
        try t.write(T.line("msg_a", cwd: T.alpha, output: 40, at: now)
                    + T.line("msg_tie", cwd: T.alpha, output: 20, at: now)
                    + T.line("msg_early", cwd: T.alpha, output: 30, at: now), cwd: T.alpha, name: "alpha.jsonl")
        service.unifiedFullScan()
        clock.now = clock.now.addingTimeInterval(61) // the today summary walks the tree again
        service.computeTodaySummaries()
        await drainMainQueue()
        let expected = ["Alpha": (all: 2, today: 2), "Beta": (all: 2, today: 2)]
        func matches(_ result: [String: (all: Int, today: Int)]) -> Bool {
            expected.allSatisfy { result[$0.key]?.all == $0.value.all && result[$0.key]?.today == $0.value.today }
        }
        #expect(service.allTimeCalls == 4 && service.todayCalls == 4)
        #expect(matches(await callsByProject(service)))

        // Cold reads of both at once (in parallel) agree, every time.
        for _ in 0..<5 {
            let cold = ClaudeDataService(claudeDir: t.history.root.path, defaults: defaults)
            cold.unifiedFullScan()
            cold.computeTodaySummaries()
            await drainMainQueue()
            #expect(cold.allTimeCalls == 4 && cold.todayCalls == 4)
            #expect(matches(await callsByProject(cold)))
        }

        // Read in the other order (Alpha alone first, then Beta): same answer.
        let reversed = try TwoProjects()
        defer { reversed.history.remove() }
        let alphaText = try String(contentsOf: t.dir(T.alpha).appendingPathComponent("alpha.jsonl"), encoding: .utf8)
        let betaText = try String(contentsOf: t.dir(T.beta).appendingPathComponent("beta.jsonl"), encoding: .utf8)
        try reversed.write(alphaText, cwd: T.alpha, name: "alpha.jsonl")
        let otherClock = TestClock()
        let other = ClaudeDataService(claudeDir: reversed.history.root.path, now: { otherClock.now }, defaults: defaults)
        other.unifiedFullScan()
        other.computeTodaySummaries()
        await drainMainQueue()
        try reversed.write(betaText, cwd: T.beta, name: "beta.jsonl")
        other.unifiedFullScan()
        otherClock.now = otherClock.now.addingTimeInterval(61)
        other.computeTodaySummaries()
        await drainMainQueue()
        #expect(other.allTimeCalls == 4 && other.todayCalls == 4)
        #expect(matches(await callsByProject(other)))
    }

    @Test func registryOwnerDoesNotDependOnClaimOrder() {
        let t = Date()
        let forward = ClaudeDataService.ResponseRegistry()
        #expect(forward.claim(1, for: "/b", at: t) == .counts)
        #expect(forward.claim(1, for: "/a", at: t) == .takesOver)
        #expect(forward.claim(1, for: "/b", at: t) == .skips)
        #expect(forward.takeDispossessed(.fullScan) == ["/b"])
        #expect(forward.takeDispossessed(.fullScan).isEmpty)
        #expect(forward.takeDispossessed(.today) == ["/b"])

        let backward = ClaudeDataService.ResponseRegistry()
        #expect(backward.claim(1, for: "/a", at: t) == .counts)
        #expect(backward.claim(1, for: "/b", at: t) == .skips)
        #expect(backward.takeDispossessed(.fullScan).isEmpty)

        // An earlier timestamp wins over the path order.
        let earlier = ClaudeDataService.ResponseRegistry()
        #expect(earlier.claim(2, for: "/a", at: t) == .counts)
        #expect(earlier.claim(2, for: "/z", at: t.addingTimeInterval(-1)) == .takesOver)
        #expect(earlier.claim(2, for: "/a", at: t) == .skips)
    }
}
