// Tests/ThothTests/ScanCorrectnessTests.swift
import Foundation
import Testing
@testable import Thoth

/// End-to-end checks of the JSONL scans against small synthetic histories in a temp directory.
///
/// The scans normally run on the service's background queue and publish through
/// `DispatchQueue.main.async`; these tests call them directly from the main actor and then
/// drain the main queue so the published values can be read.
@MainActor
@Suite(.serialized)
struct ScanCorrectnessTests {
    private static let models = [
        "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1",
        "claude-opus-4-6", "claude-haiku-4-5-20251001", "<synthetic>",
    ]

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func cost(_ r: SyntheticHistory.Request) -> Double {
        TokenUsage(inputTokens: r.input, outputTokens: r.output, cacheWriteTokens: r.cacheWrite,
                   cacheReadTokens: r.cacheRead, cacheWrite1hTokens: r.cacheWrite1h).cost(for: r.model)
    }

    private func priced(_ requests: [SyntheticHistory.Request]) -> [SyntheticHistory.Request] {
        requests.filter { ModelPricing.forModel($0.model) != nil }
    }

    @Test func fullScanCountsEachResponseOnce() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 7)
        defer { history.remove() }
        try history.generate(projects: 4, filesPerProject: 3, messagesPerFile: 60, todayShare: 0.3)

        let service = ClaudeDataService(claudeDir: history.root.path)
        service.unifiedFullScan()
        await drainMainQueue()

        let requests = priced(history.requests)
        #expect(service.allTimeCalls == requests.count)
        #expect(service.allTimeTokens == requests.reduce(0) { $0 + $1.totalTokens })
        let expectedCost = requests.reduce(0.0) { $0 + cost($1) }
        #expect(abs(service.allTimeCost - expectedCost) < 1e-6 * max(expectedCost, 1))
        #expect(service.allTimeCost > 0)

        // Model breakdown: one row per canonical model, Claude 5 included, <synthetic> excluded.
        let rows = Set(service.modelUsage.entries.map(\.modelId))
        #expect(rows == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1",
                         "claude-opus-4-6", "claude-haiku-4-5"])
        let rowCost = service.modelUsage.entries.reduce(0.0) { $0 + $1.totalCost }
        #expect(abs(rowCost - expectedCost) < 1e-6 * max(expectedCost, 1))

        // Rolling windows count today as day one: 7 Days = today and the 6 days before.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func calls(since days: Int) -> Int {
            let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
            return requests.filter { cal.startOfDay(for: $0.date) >= start }.count
        }
        #expect(service.weekCalls == calls(since: 7))
        #expect(service.fifteenDaysCalls == calls(since: 15))
        #expect(service.monthCalls == calls(since: 30))
        #expect(service.dailyCostSeries.count == 30)
    }

    @Test func todaySummaryCountsResponsesOnceAndClassifiesAllTheirTools() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 11)
        defer { history.remove() }
        try history.generate(projects: 2, filesPerProject: 3, messagesPerFile: 40, todayShare: 1.0)

        let service = ClaudeDataService(claudeDir: history.root.path)
        service.computeTodaySummaries()
        await drainMainQueue()

        let today = Calendar.current.startOfDay(for: Date())
        let requests = priced(history.requests).filter { $0.date >= today }
        #expect(service.todayCalls == requests.count)
        #expect(service.todayTokens == requests.reduce(0) { $0 + $1.totalTokens })

        var expected: [ActivityCategory: Int] = [:]
        for r in requests { expected[ActivityCategory.classify(tools: r.tools), default: 0] += 1 }
        let actual = service.todayActivity.entries.mapValues(\.turns)
        #expect(actual == expected)
    }

    @Test func incrementalReadsWaitForCompleteLinesAndJoinSplitResponses() async throws {
        let history = try SyntheticHistory(models: [], seed: 1)
        defer { history.remove() }
        let dir = history.projectsDir.appendingPathComponent("-home-dev-Documents-Demo-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")

        let ts = SyntheticHistory.timestamp(Date())
        func line(_ id: String, _ block: String) -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[\#(block)],"usage":{"input_tokens":1000,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
                + "\n"
        }
        let thinking = #"{"type":"thinking","thinking":""}"#
        let edit = #"{"type":"tool_use","name":"Edit","input":{}}"#
        let a1 = line("msg_a", thinking), a2 = line("msg_a", edit), b1 = line("msg_b", thinking)

        let service = ClaudeDataService(claudeDir: history.root.path)
        var mtime = Date()
        func write(_ text: String, append: Bool = true) throws {
            if append {
                let h = try FileHandle(forWritingTo: file)
                try h.seekToEnd()
                try h.write(contentsOf: Data(text.utf8))
                try h.close()
            } else {
                try Data(text.utf8).write(to: file)
            }
            mtime = mtime.addingTimeInterval(1) // force a visible mtime change between steps
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }

        // Step 1: first block of response A plus half of its second line.
        let half = a2.index(a2.startIndex, offsetBy: a2.count / 2)
        try write(a1 + a2[..<half], append: false)
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.todayCalls == 1)

        // Step 2: the rest of A's tool_use line, then response B.
        try write(String(a2[half...]) + b1)
        service.computeTodaySummaries()
        await drainMainQueue()

        let perResponse = 1000 * 4.0 / 1_000_000 + 2000 * 20.0 / 1_000_000
        #expect(service.todayCalls == 2)
        #expect(abs(service.todayCost - 2 * perResponse) < 1e-9)
        // A's Edit arrived on a later line of the same response: A is coding, not conversation.
        #expect(service.todayActivity.entries[.coding]?.turns == 1)
        #expect(service.todayActivity.entries[.conversation]?.turns == 1) // B, thinking only
    }

    @Test func activeSessionPollFindsFoldersOfCwdsWithSpaces() async throws {
        var history = try SyntheticHistory(models: ["claude-sonnet-5-5"], seed: 3)
        defer { history.remove() }
        try history.generate(projects: 1, filesPerProject: 2, messagesPerFile: 10,
                             cwdBase: "/srv/synthetic/Documents/Client Work - 2026")
        try history.writeSession(forFileAt: 0)

        let service = ClaudeDataService(claudeDir: history.root.path)
        service.loadSessions()
        service.unifiedFullScan()
        await drainMainQueue()
        let before = service.totalTokens

        let already = history.requests.count
        try history.append(messages: 5, toFiles: 1)
        let appended = history.requests[already...]
        service.pollActiveSessions()
        await drainMainQueue()

        #expect(service.totalTokens - before == appended.reduce(0) { $0 + $1.totalTokens })
        #expect(service.burnRateTracker.currentRate > 0)
    }

    @Test func projectRankingJoinsWorktreesToTheirProject() async throws {
        let base = "/srv/synthetic/Documents"
        let cwds = [
            "\(base)/Internal - Dev",                     // parent folder
            "\(base)/Internal - Dev/site",                // project inside it
            "/srv/synthetic/Library/Application Support/Horus/parallel-worktrees/site-d9470035/horus-conversa-0a1b2c3d-task",
            "\(base)/Acme/app",
            "\(base)/Acme/app/.claude/worktrees/feature-x",
            "/private/tmp/claude-501/-srv-synthetic-Documents-Acme-app/441215ec-fa16-4c61-9222-046e26d390cf/scratchpad",
        ]
        var history = try SyntheticHistory(models: ["claude-opus-5-5", "claude-sonnet-5-5"], seed: 5)
        defer { history.remove() }
        try history.generate(projects: cwds.count, filesPerProject: 2, messagesPerFile: 15, cwds: cwds)

        let service = ClaudeDataService(claudeDir: history.root.path)
        service.unifiedFullScan()
        await drainMainQueue()

        // Per-file cost, by the group of the project the file's cwd belongs to.
        var expected: [String: Double] = [:]
        let perFile = 15
        for (index, file) in history.files.enumerated() {
            let group = file.cwd.contains("Acme") ? "Acme" : "Internal - Dev"
            let requests = history.requests[(index * perFile)..<((index + 1) * perFile)]
            expected[group, default: 0] += requests.reduce(0.0) { $0 + cost($1) }
        }
        #expect(service.projectRanking.map(\.name) == ["Acme", "Internal - Dev"]
                || service.projectRanking.map(\.name) == ["Internal - Dev", "Acme"])
        for row in service.projectRanking {
            #expect(abs(row.cost - expected[row.name, default: -1]) < 1e-9 * max(row.cost, 1))
        }
        #expect(abs(service.projectRanking.reduce(0) { $0 + $1.cost } - service.allTimeCost) < 1e-9 * service.allTimeCost)
    }

    @Test func projectDirNameMatchesClaudeCodeEncoding() {
        #expect(ClaudeDataService.projectDirName(forCwd: "/home/dev/Documents/Acme/app") == "-home-dev-Documents-Acme-app")
        #expect(ClaudeDataService.projectDirName(forCwd: "/a/My Project_v1.2") == "-a-My-Project-v1-2")
        #expect(ClaudeDataService.projectDirName(forCwd: "/a/Projetos - Ação") == "-a-Projetos---A--o")
    }
}
