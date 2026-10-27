// Tests/ThothTests/LogFormatCompatibilityTests.swift
import Foundation
import Testing
@testable import Thoth

/// Compatibility checks against the transcript format, which Claude Code controls and may change.
///
/// Every `Fixtures/LogFormat/<name>.jsonl` comes with a `<name>.expected.json` holding the totals
/// it must produce. Each fixture is read whole, in chunks of several sizes, while it grows, and by
/// the heavy scan of `ClaudeDataService`; all of them must give the same calls, tokens and cost,
/// and report the same ignored lines. Fixtures are synthetic: no real transcript content.
@MainActor
@Suite(.serialized)
struct LogFormatCompatibilityTests {

    // MARK: - Fixtures

    struct Expectation: Decodable {
        struct Tokens: Decodable, Equatable {
            var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
        }
        struct Ignored: Decodable, Equatable {
            var malformed = 0, incomplete = 0
        }
        let description: String
        /// Where the file sits in its project folder; a session's main transcript by default.
        let path: String?
        /// Dated responses of Claude models: what the heavy scan counts.
        let calls: Int
        let tokens: Tokens
        /// USD, at the rates of `ModelPricing.all`; models without a known price add 0.
        let cost: Double
        /// Model rows (canonical ids) of the counted responses.
        let models: [String]
        /// Responses that aren't counted (`<synthetic>`, other vendors' models).
        let uncountedCalls: Int?
        /// Responses without a usable timestamp are not reported: they are `incomplete` lines.
        let ignored: Ignored
    }

    /// What one read produced, in the terms of `Expectation`.
    struct Totals: Equatable {
        var calls = 0, uncountedCalls = 0
        var tokens = Expectation.Tokens()
        var cost = 0.0
        var models: Set<String> = []
        var ignored = Expectation.Ignored()

        mutating func add(_ record: UsageRecord) {
            let newCall = record.isCorrection ? 0 : 1
            guard record.isCounted else { uncountedCalls += newCall; return }
            calls += newCall
            tokens.input += record.usage.inputTokens
            tokens.output += record.usage.outputTokens
            tokens.cacheWrite += record.usage.cacheWriteTokens
            tokens.cacheRead += record.usage.cacheReadTokens
            cost += record.cost
            models.insert(ModelUsageEntry.key(for: record.model))
        }

        mutating func add(_ ignoredLine: IgnoredLine) {
            switch ignoredLine {
            case .malformed: ignored.malformed += 1
            case .incomplete: ignored.incomplete += 1
            }
        }

        /// Cost is compared within rounding; everything else exactly.
        func matches(_ other: Totals) -> Bool {
            var a = self, b = other
            a.cost = 0; b.cost = 0
            return a == b && abs(cost - other.cost) < 1e-9
        }

        init() {}

        init(_ e: Expectation) {
            calls = e.calls
            uncountedCalls = e.uncountedCalls ?? 0
            tokens = e.tokens
            cost = e.cost
            models = Set(e.models)
            ignored = e.ignored
        }
    }

    struct Fixture {
        let name: String
        let data: Data
        let expectation: Expectation
        var relativePath: String { expectation.path ?? "session.jsonl" }
        /// Bytes up to the last line break: a final line without one is still being written.
        var completeBytes: Int { (data.lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0 }
    }

    nonisolated static let fixtureDir = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/LogFormat")

    nonisolated static let fixtureNames: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: fixtureDir.path)) ?? []
        return files.filter { $0.hasSuffix(".expected.json") }
            .map { String($0.dropLast(".expected.json".count)) }
            .sorted()
    }()

    static func fixture(_ name: String) throws -> Fixture {
        let data = try Data(contentsOf: fixtureDir.appendingPathComponent(name + ".jsonl"))
        let json = try Data(contentsOf: fixtureDir.appendingPathComponent(name + ".expected.json"))
        return Fixture(name: name, data: data, expectation: try JSONDecoder().decode(Expectation.self, from: json))
    }

    // MARK: - Readers

    private func parseWhole(_ data: Data) -> (totals: Totals, consumed: Int) {
        var totals = Totals()
        var open: OpenResponse?
        let consumed = UsageLogParser.parse(data, open: &open, onIgnored: { totals.add($0) }) { totals.add($0) }
        return (totals, consumed)
    }

    private func parseFile(at url: URL, cursor: inout UsageLogCursor, into totals: inout Totals,
                           chunkSize: Int = 256 << 10) {
        var read = totals
        UsageLogParser.parseFile(atPath: url.path, cursor: &cursor, chunkSize: chunkSize,
                                 onIgnored: { read.add($0) }) { read.add($0) }
        totals = read
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("thoth-format-\(UUID().uuidString).jsonl")
    }

    /// Offsets where a growing copy of `data` is cut: the middle and the end of every line.
    private func cutPoints(_ data: Data) -> [Int] {
        var cuts: [Int] = []
        var lineStart = 0
        for (i, byte) in data.enumerated() where byte == 0x0A {
            cuts.append(lineStart + (i - lineStart) / 2)
            cuts.append(i + 1)
            lineStart = i + 1
        }
        cuts.append(data.count)
        return cuts.filter { $0 > 0 }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Checks shared by every fixture

    private func checkParser(_ fixture: Fixture, chunkSizes: [Int]) throws {
        let expected = Totals(fixture.expectation)
        let name = fixture.name

        let whole = parseWhole(fixture.data)
        #expect(whole.totals.matches(expected), "\(name): whole read \(whole.totals) != \(expected)")
        #expect(whole.consumed == fixture.completeBytes, "\(name)")

        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.data.write(to: url)
        for chunkSize in chunkSizes {
            var cursor = UsageLogCursor()
            var totals = Totals()
            parseFile(at: url, cursor: &cursor, into: &totals, chunkSize: chunkSize)
            #expect(totals.matches(expected), "\(name), chunk \(chunkSize): \(totals)")
            #expect(cursor.offset == UInt64(fixture.completeBytes), "\(name), chunk \(chunkSize)")
        }

        // The file grows between reads, cut mid-line and between the lines of one response.
        try Data().write(to: url)
        var cursor = UsageLogCursor()
        var totals = Totals()
        var written = 0
        for cut in cutPoints(fixture.data) where cut > written {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: fixture.data[written..<cut])
            try handle.close()
            written = cut
            parseFile(at: url, cursor: &cursor, into: &totals, chunkSize: 4_096)
            #expect(totals.calls <= expected.calls, "\(name): more calls than responses at byte \(cut)")
        }
        #expect(totals.matches(expected), "\(name), growing: \(totals)")
        #expect(cursor.offset == UInt64(fixture.completeBytes), "\(name), growing")
    }

    private func checkFullScan(_ fixture: Fixture) async throws {
        let e = fixture.expectation
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects/-srv-fixture-app/" + fixture.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        let service = ClaudeDataService(claudeDir: root.path)
        var mtime = Date(timeIntervalSince1970: 1_800_000_000)
        func scan(_ bytes: Data) async throws {
            try bytes.write(to: file)
            mtime = mtime.addingTimeInterval(60)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            service.unifiedFullScan()
            await drainMainQueue()
        }

        // First half (cut mid-line), then the whole file: the second scan reads only what grew.
        try await scan(fixture.data.prefix(fixture.data.count / 2))
        #expect(service.allTimeCalls <= e.calls, "\(fixture.name)")
        try await scan(fixture.data)

        let expectedTokens = e.tokens.input + e.tokens.output + e.tokens.cacheWrite + e.tokens.cacheRead
        #expect(service.allTimeCalls == e.calls, "\(fixture.name)")
        #expect(service.allTimeTokens == expectedTokens, "\(fixture.name)")
        #expect(abs(service.allTimeCost - e.cost) < 1e-9, "\(fixture.name): \(service.allTimeCost)")
        #expect(Set(service.modelUsage.entries.map(\.modelId)) == Set(e.models), "\(fixture.name)")
        let rowCost = service.modelUsage.entries.reduce(0.0) { $0 + $1.totalCost }
        #expect(abs(rowCost - e.cost) < 1e-9, "\(fixture.name)")

        // A cold scan of the finished file agrees with the incremental one.
        let cold = ClaudeDataService(claudeDir: root.path)
        cold.unifiedFullScan()
        await drainMainQueue()
        #expect(cold.allTimeCalls == service.allTimeCalls && cold.allTimeTokens == service.allTimeTokens,
                "\(fixture.name)")
    }

    // MARK: - Tests

    /// The format variations this suite must keep covering.
    @Test func fixturesCoverEveryKnownVariation() {
        let required: Set<String> = [
            "malformed-lines", "missing-fields", "unknown-fields", "unknown-record-types",
            "unknown-model-ids", "streaming-repeats", "sidechain-subagent", "compaction-summary",
            "cache-usage-variants", "timestamps", "growing-file",
        ]
        #expect(required.isSubset(of: Set(Self.fixtureNames)),
                "missing: \(required.subtracting(Self.fixtureNames).sorted())")
    }

    @Test(arguments: fixtureNames)
    func parserTotalsMatchTheFixture(_ name: String) throws {
        try checkParser(try Self.fixture(name), chunkSizes: [1, 7, 64, 4_096, 256 << 10])
    }

    @Test(arguments: fixtureNames)
    func fullScanTotalsMatchTheFixture(_ name: String) async throws {
        try await checkFullScan(try Self.fixture(name))
    }

    /// Every accepted timestamp shape lands on the same instant as Claude Code's own form.
    @Test func timestampsKeepTheirInstant() throws {
        let fixture = try Self.fixture("timestamps")
        var dates: [String: Date] = [:]
        var ignored: [IgnoredLine] = []
        var open: OpenResponse?
        UsageLogParser.parse(fixture.data, open: &open, onIgnored: { ignored.append($0) }) {
            dates[$0.messageId ?? ""] = $0.timestamp
        }
        let base = UsageLogParser.parseTimestamp("2026-10-20T10:00:00.000Z")!
        let offsets: [String: Double] = ["msg_t0": 0, "msg_t1": 1, "msg_t2": 2, "msg_t3": 3.123, "msg_t4": 4.5, "msg_t5": 5]
        for (id, offset) in offsets {
            let date = dates[id]
            #expect(date.map { abs($0.timeIntervalSince(base) - offset) < 0.001 } == true, "\(id): \(String(describing: date))")
        }
        // No zone: ignored as incomplete, not reported.
        #expect(dates["msg_t6"] == nil)
        #expect(ignored == [.incomplete])
    }

    /// Lines of several megabytes, far longer than a read chunk, with and without usage.
    @Test func longLinesAreReadWhole() async throws {
        let big = String(repeating: "lorem ipsum ", count: 130_000) // ~1.5 MB
        let medium = String(repeating: "dolor sit ", count: 60_000) // ~600 KB
        func assistant(_ id: String, _ model: String, _ block: String, input: Int, output: Int) -> String {
            #"{"type":"assistant","timestamp":"2026-10-20T20:00:00.000Z","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"\#(model)","content":[\#(block)],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}"#
                + "\n"
        }
        let text = #"{"type":"user","timestamp":"2026-10-20T20:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"\#(big)"}]}}"# + "\n"
            + assistant("msg_l1", "claude-opus-5-5", #"{"type":"text","text":"\#(medium)"}"#, input: 1000, output: 10)
            // A tool input that happens to hold a "usage" object is not the response's usage.
            + assistant("msg_l1", "claude-opus-5-5",
                        #"{"type":"tool_use","name":"Write","input":{"usage":{"input_tokens":999},"content":"\#(medium)"}}"#,
                        input: 1000, output: 500)
            + #"{"type":"user","message":{"role":"user","content":"\#(big)"# + "\n" // cut short
            + assistant("msg_l2", "claude-sonnet-5-5", #"{"type":"text","text":"short"}"#, input: 10, output: 10)
        let json = #"""
        {"description":"generated","calls":2,"tokens":{"input":1010,"output":510,"cacheWrite":0,"cacheRead":0},
         "cost":0.01412,"models":["claude-opus-5-5","claude-sonnet-5-5"],"ignored":{"malformed":1,"incomplete":0}}
        """#
        let fixture = Fixture(name: "long-lines (generated)", data: Data(text.utf8),
                              expectation: try JSONDecoder().decode(Expectation.self, from: Data(json.utf8)))
        try checkParser(fixture, chunkSizes: [4_096, 65_536, 256 << 10])
        try await checkFullScan(fixture)
    }

    /// A resumed or forked session can start a new transcript that repeats responses already
    /// logged in the one it came from (same message id and request id): they count once.
    @Test func responsesCopiedIntoAnotherSessionAreCountedOnce() async throws {
        let fixture = try Self.fixture("streaming-repeats")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("projects/-srv-fixture-app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fixture.data.write(to: dir.appendingPathComponent("original.jsonl"))
        try fixture.data.write(to: dir.appendingPathComponent("resumed.jsonl"))

        let service = ClaudeDataService(claudeDir: root.path)
        service.unifiedFullScan()
        await drainMainQueue()
        let e = fixture.expectation
        #expect(service.allTimeCalls == e.calls)
        #expect(service.allTimeTokens == e.tokens.input + e.tokens.output + e.tokens.cacheWrite + e.tokens.cacheRead)
        #expect(abs(service.allTimeCost - e.cost) < 1e-9)
    }
}
