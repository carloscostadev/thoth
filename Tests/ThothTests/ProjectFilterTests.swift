// Tests/ThothTests/ProjectFilterTests.swift
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
        #expect(service.availableProjects == ["Group0", "Group1", "Group2", "Group3", "Group4"])
        let unfilteredCalls = service.allTimeCalls
        let unfilteredToday = service.todayCalls

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func since(_ days: Int) -> Date { cal.date(byAdding: .day, value: -(days - 1), to: today)! }

        var sumOfProjects = 0
        for group in service.availableProjects {
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
            // The picker still lists every project.
            #expect(service.availableProjects.count == 5)
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
        #expect(second.availableProjects == ["Group0", "Group2"])
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
