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

    /// Everything the full scan publishes, for comparing two services.
    private func expectSameScan(_ a: ClaudeDataService, _ b: ClaudeDataService) {
        func close(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= 1e-9 * max(abs(x), abs(y), 1) }
        #expect(a.allTimeCalls == b.allTimeCalls)
        #expect(a.allTimeTokens == b.allTimeTokens)
        #expect(close(a.allTimeCost, b.allTimeCost))
        #expect(a.weekCalls == b.weekCalls && a.fifteenDaysCalls == b.fifteenDaysCalls && a.monthCalls == b.monthCalls)
        #expect(close(a.weekCost, b.weekCost) && close(a.monthCost, b.monthCost))
        #expect(a.weekTokens == b.weekTokens && a.monthTokens == b.monthTokens)
        let rows = { (s: ClaudeDataService) in s.modelUsage.entries.sorted { $0.modelId < $1.modelId } }
        #expect(rows(a).map(\.modelId) == rows(b).map(\.modelId))
        for (x, y) in zip(rows(a), rows(b)) {
            #expect(x.inputTokens == y.inputTokens && x.outputTokens == y.outputTokens)
            #expect(x.cacheWriteTokens == y.cacheWriteTokens && x.cacheReadTokens == y.cacheReadTokens)
            #expect(x.sessionCount == y.sessionCount)
            #expect(close(x.totalCost, y.totalCost))
        }
        #expect(a.dailyCostSeries.map(\.date) == b.dailyCostSeries.map(\.date))
        #expect(a.dailyCostSeries.map(\.tokens) == b.dailyCostSeries.map(\.tokens))
        #expect(zip(a.dailyCostSeries, b.dailyCostSeries).allSatisfy { close($0.cost, $1.cost) })
        #expect(zip(a.heatmap.joined(), b.heatmap.joined()).allSatisfy { close($0, $1) })
        #expect(a.projectRanking.map(\.name) == b.projectRanking.map(\.name))
        #expect(close(a.cacheSavings, b.cacheSavings) && close(a.cacheHitRate, b.cacheHitRate))
    }

    private func coldScan(_ root: URL) async -> ClaudeDataService {
        let cold = ClaudeDataService(claudeDir: root.path)
        cold.unifiedFullScan()
        await drainMainQueue()
        return cold
    }

    @Test func fullScanReadsOnlyWhatGrewAndMatchesAColdScan() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 13)
        defer { history.remove() }
        try history.generate(projects: 3, filesPerProject: 3, messagesPerFile: 30, todayShare: 0.5)

        let service = ClaudeDataService(claudeDir: history.root.path)
        service.unifiedFullScan()
        for _ in 0..<3 {
            try history.append(messages: 7, toFiles: 4)
            service.unifiedFullScan()
        }
        await drainMainQueue()

        let requests = priced(history.requests)
        #expect(service.allTimeCalls == requests.count)
        #expect(service.allTimeTokens == requests.reduce(0) { $0 + $1.totalTokens })
        expectSameScan(service, await coldScan(history.root))
    }

    @Test func fullScanJoinsAResponseSplitBetweenScans() async throws {
        let history = try SyntheticHistory(models: [], seed: 1)
        defer { history.remove() }
        let dir = history.projectsDir.appendingPathComponent("-srv-Documents-Acme-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        let ts = SyntheticHistory.timestamp(Date())
        func line(_ id: String, output: Int) -> String {
            #"{"type":"assistant","cwd":"/srv/Documents/Acme/app","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":1000,"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
                + "\n"
        }
        var mtime = Date()
        func append(_ text: String) throws {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: file)
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
            try h.close()
            mtime = mtime.addingTimeInterval(1)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }

        let service = ClaudeDataService(claudeDir: history.root.path)
        let a2 = line("msg_a", output: 3000)
        let half = a2.index(a2.startIndex, offsetBy: a2.count / 2)
        try append(line("msg_a", output: 100) + a2[..<half])
        service.unifiedFullScan()
        try append(String(a2[half...]) + line("msg_b", output: 50))
        service.unifiedFullScan()
        try append(line("msg_b", output: 500))
        service.unifiedFullScan()
        await drainMainQueue()

        #expect(service.allTimeCalls == 2)
        #expect(service.allTimeTokens == 2 * 1000 + 3000 + 500)
        #expect(abs(service.allTimeCost - (2000 * 4.0 + 3500 * 20.0) / 1_000_000) < 1e-12)
        expectSameScan(service, await coldScan(history.root))
    }

    @Test func fullScanRereadsReplacedOrRewrittenFiles() async throws {
        var history = try SyntheticHistory(models: Self.models, seed: 17)
        defer { history.remove() }
        try history.generate(projects: 1, filesPerProject: 2, messagesPerFile: 20, todayShare: 1)
        let service = ClaudeDataService(claudeDir: history.root.path)
        service.unifiedFullScan()

        // Replaced by a longer file (new inode), as an editor or a sync tool would.
        let replaced = history.files[0].url
        let original = try Data(contentsOf: replaced)
        let other = try Data(contentsOf: history.files[1].url)
        try (other + other).write(to: replaced, options: .atomic)
        // Rewritten in place (same inode), longer, without a line break where the last read ended.
        let rewritten = history.files[1].url
        let readUpTo = other.count
        let handle = try FileHandle(forWritingTo: rewritten)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(String(repeating: "x", count: readUpTo).utf8) + Data("\n".utf8) + original)
        try handle.close()
        let later = Date().addingTimeInterval(5)
        for url in [replaced, rewritten] {
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        }

        service.unifiedFullScan()
        await drainMainQueue()
        expectSameScan(service, await coldScan(history.root))
    }

    /// Agent-tool runs write `<session>/subagents/agent-*.jsonl` (sidechain lines); every scan
    /// counts them like the main transcript, and the active-session poll follows them too.
    @Test func subagentTranscriptsAreCountedByEveryScan() async throws {
        var history = try SyntheticHistory(models: ["claude-opus-5-5", "claude-haiku-5-5"], seed: 23)
        defer { history.remove() }
        try history.generate(projects: 1, filesPerProject: 2, messagesPerFile: 12, todayShare: 1)
        // Move the second file to the first session's subagents folder.
        let main = history.files[0].url
        let sessionId = main.deletingPathExtension().lastPathComponent
        let subagents = main.deletingLastPathComponent().appendingPathComponent("\(sessionId)/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let agent = subagents.appendingPathComponent("agent-a1b2.jsonl")
        try FileManager.default.moveItem(at: history.files[1].url, to: agent)
        try history.writeSession(forFileAt: 0)

        let service = ClaudeDataService(claudeDir: history.root.path)
        service.loadSessions()
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        let requests = priced(history.requests)
        #expect(service.allTimeCalls == requests.count)
        #expect(service.todayCalls == requests.count)

        // A sub-run appended while the session is live reaches the totals through the poll.
        let before = service.totalTokens
        let line = #"{"type":"assistant","isSidechain":true,"timestamp":"\#(SyntheticHistory.timestamp(Date()))","message":{"id":"msg_sub","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":700,"output_tokens":300,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let handle = try FileHandle(forWritingTo: agent)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        service.pollActiveSessions()
        await drainMainQueue()
        #expect(service.totalTokens - before == 1_000)
    }

    // MARK: - Counting consistency

    /// Settable clock, to get past the today summary's one-minute walk interval.
    private final class TestClock: @unchecked Sendable {
        var now = Date()
    }

    /// A transcript folder for `cwd`, the response lines written into it, and a live session.
    private struct Transcripts {
        static let cwd = "/srv/Documents/Acme/app"
        let history: SyntheticHistory
        var dir: URL { history.projectsDir.appendingPathComponent(SyntheticHistory.encode(cwd: Self.cwd)) }

        init() throws {
            history = try SyntheticHistory(models: [], seed: 1)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        /// One line of response `id`; `ts: nil` writes no timestamp.
        static func line(_ id: String, model: String = "claude-opus-5-5", input: Int = 1000, output: Int,
                         ts: String? = SyntheticHistory.timestamp(Date().addingTimeInterval(-30))) -> String {
            let timestamp = ts.map { #""timestamp":"\#($0)","# } ?? ""
            return #"{"type":"assistant","cwd":"\#(cwd)",\#(timestamp)"requestId":"req_\#(id)","message":{"id":"\#(id)","model":"\#(model)","content":[],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
                + "\n"
        }

        func write(_ text: String, to name: String, append: Bool = false) throws {
            let url = dir.appendingPathComponent(name)
            if append, let h = FileHandle(forWritingAtPath: url.path) {
                try h.seekToEnd()
                try h.write(contentsOf: Data(text.utf8))
                try h.close()
            } else {
                try Data(text.utf8).write(to: url)
            }
            // A visible mtime change for each write, still today.
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            try FileManager.default.setAttributes([.modificationDate: max(mtime, Date()).addingTimeInterval(1)],
                                                  ofItemAtPath: url.path)
        }

        /// Heartbeat of a live session whose transcript is `<sessionId>.jsonl`.
        func startSession(_ sessionId: String) throws {
            let json: [String: Any] = [
                "pid": Int(getpid()), "sessionId": sessionId, "cwd": Self.cwd,
                "startedAt": Int64(Date().timeIntervalSince1970 * 1000), "kind": "interactive", "entrypoint": "cli",
            ]
            try JSONSerialization.data(withJSONObject: json)
                .write(to: history.root.appendingPathComponent("sessions/\(sessionId).json"))
        }
    }

    /// Opus 5.5 at 1000 input tokens: input $4 / MTok, output $20 / MTok.
    private func opusCost(output: Int) -> Double { (1000 * 4.0 + Double(output) * 20.0) / 1_000_000 }

    /// A resumed session's transcript repeats responses of the original one: the heavy scan
    /// (cold and incremental), the today summary and the active-session poll all count them once,
    /// and they still count once the original transcript is gone.
    @Test func copiedResponsesCountOnceInEveryScan() async throws {
        let t = try Transcripts()
        defer { t.history.remove() }
        let clock = TestClock()
        let service = ClaudeDataService(claudeDir: t.history.root.path, now: { clock.now })
        typealias T = Transcripts
        let r1 = T.line("msg_1", output: 10) + T.line("msg_1", output: 200)
        let r2 = T.line("msg_2", output: 300)
        try t.write(r1 + r2, to: "original.jsonl")
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.allTimeCalls == 2 && service.todayCalls == 2)

        // Resumed: the copies first (the stream's last line only), then a new response while live.
        try t.write(T.line("msg_1", output: 200) + r2, to: "resumed.jsonl")
        try t.startSession("resumed")
        service.loadSessions()
        let before = service.totalTokens
        try t.write(T.line("msg_3", output: 50), to: "resumed.jsonl", append: true)
        service.pollActiveSessions()
        await drainMainQueue()
        #expect(service.totalTokens - before == 1050)

        let expectedTokens = 3 * 1000 + 200 + 300 + 50
        let expectedCost = opusCost(output: 200) + opusCost(output: 300) + opusCost(output: 50)
        service.unifiedFullScan()
        clock.now = clock.now.addingTimeInterval(61) // the today summary walks the tree again
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.allTimeCalls == 3)
        #expect(service.allTimeTokens == expectedTokens)
        #expect(abs(service.allTimeCost - expectedCost) < 1e-12)
        #expect(service.todayCalls == 3 && service.todayTokens == expectedTokens)
        #expect(abs(service.todayCost - expectedCost) < 1e-12)
        expectSameScan(service, await coldScan(t.history.root))

        // The original is deleted: the resumed transcript now counts the copies.
        try FileManager.default.removeItem(at: t.dir.appendingPathComponent("original.jsonl"))
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.allTimeCalls == 3 && service.allTimeTokens == expectedTokens)
        #expect(service.todayCalls == 3 && service.todayTokens == expectedTokens)
        expectSameScan(service, await coldScan(t.history.root))
    }

    /// A Claude model of an unknown family counts in calls and tokens, at no cost, in every scan,
    /// and gets a row marked as having no known price.
    @Test func unknownFamilyModelsCountWithoutCost() async throws {
        let t = try Transcripts()
        defer { t.history.remove() }
        try t.write(Transcripts.line("msg_n", model: "claude-nova-1-0", output: 500)
                    + Transcripts.line("msg_o", output: 100)
                    + Transcripts.line("msg_s", model: "<synthetic>", input: 0, output: 0), to: "session.jsonl")
        let service = ClaudeDataService(claudeDir: t.history.root.path)
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()

        #expect(service.allTimeCalls == 2 && service.todayCalls == 2)
        #expect(service.allTimeTokens == 2600 && service.todayTokens == 2600)
        #expect(abs(service.allTimeCost - opusCost(output: 100)) < 1e-12)
        #expect(abs(service.todayCost - opusCost(output: 100)) < 1e-12)
        let rows = Dictionary(uniqueKeysWithValues: service.modelUsage.entries.map { ($0.modelId, $0) })
        #expect(Set(rows.keys) == ["claude-nova-1-0", "claude-opus-5-5"])
        let nova = try #require(rows["claude-nova-1-0"])
        #expect(nova.totalTokens == 1500 && nova.totalCost == 0 && nova.sessionCount == 1)
        #expect(nova.hasNoKnownPrice && !nova.hasApproximatePricing)
        #expect(rows["claude-opus-5-5"]?.hasNoKnownPrice == false)
    }

    /// A response without a usable timestamp belongs to no day: the heavy scan, the today
    /// summary and the active-session poll all leave it out.
    @Test func undatedResponsesAreLeftOutByEveryScan() async throws {
        let t = try Transcripts()
        defer { t.history.remove() }
        typealias T = Transcripts
        try t.write(T.line("msg_a", output: 100) + T.line("msg_u", output: 900, ts: nil)
                    + T.line("msg_z", output: 900, ts: "2026-10-20T10:00:00.000"), to: "live.jsonl")
        try t.startSession("live")
        let service = ClaudeDataService(claudeDir: t.history.root.path)
        service.loadSessions()
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.allTimeCalls == 1 && service.todayCalls == 1)
        #expect(service.allTimeTokens == 1100 && service.todayTokens == 1100)

        // Appended while live: an undated response, then a dated one.
        let before = service.totalTokens
        try t.write(T.line("msg_v", output: 900, ts: nil) + T.line("msg_b", output: 200), to: "live.jsonl", append: true)
        service.pollActiveSessions()
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.totalTokens - before == 1200)
        #expect(service.allTimeCalls == 2 && service.todayCalls == 2)
        #expect(service.allTimeTokens == 2300 && service.todayTokens == 2300)
        #expect(abs(service.todayCost - service.allTimeCost) < 1e-12)
    }

    @Test func projectDirNameMatchesClaudeCodeEncoding() {
        #expect(ClaudeDataService.projectDirName(forCwd: "/home/dev/Documents/Acme/app") == "-home-dev-Documents-Acme-app")
        #expect(ClaudeDataService.projectDirName(forCwd: "/a/My Project_v1.2") == "-a-My-Project-v1-2")
        #expect(ClaudeDataService.projectDirName(forCwd: "/a/Projetos - Ação") == "-a-Projetos---A--o")
    }
}
