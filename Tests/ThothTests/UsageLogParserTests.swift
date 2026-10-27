// Tests/ThothTests/UsageLogParserTests.swift
import Foundation
import Testing
@testable import Thoth

private func line(id: String, model: String = "claude-sonnet-5-5", block: String = #"{"type":"text","text":"hi"}"#,
                  input: Int = 10, output: Int = 5, ts: String = "2026-10-23T09:12:34.567Z") -> String {
    #"{"type":"assistant","cwd":"/srv/x/Documents/G/p","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","content":[\#(block)],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        + "\n"
}

@Test func fastTimestampMatchesISO8601Formatter() {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let samples = ["2026-10-23T09:12:34.567Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.000Z",
                   "2026-01-01T00:00:00.001Z", "2100-03-01T12:00:00.500Z"]
    for s in samples {
        let fast = UsageLogParser.parseTimestamp(s)
        let reference = formatter.date(from: s)
        #expect(fast != nil && reference != nil && abs(fast!.timeIntervalSince(reference!)) < 0.0005, "\(s)")
    }
    // Other ISO 8601 shapes fall back to the formatter instead of failing.
    #expect(UsageLogParser.parseTimestamp("2026-10-23T10:12:34.567+01:00") == UsageLogParser.parseTimestamp("2026-10-23T09:12:34.567Z"))
    #expect(UsageLogParser.parseTimestamp("2026-13-23T09:12:34.567Z") == nil)
    #expect(UsageLogParser.parseTimestamp("not a date") == nil)
}

@Test func parsesOnlyCompleteLinesAndDeduplicatesResponses() {
    let text = line(id: "a") + line(id: "a", block: #"{"type":"tool_use","name":"Bash","input":{}}"#)
        + line(id: "b") + #"{"type":"assistant","message":{"id":"c""#
    let data = Data(text.utf8)
    var open: OpenResponse?
    var records: [UsageRecord] = []
    var continuations: [[String]] = []
    var cwd: String?
    let consumed = UsageLogParser.parse(data, open: &open, onCwd: { cwd = $0 },
                                        onContinuation: { continuations.append($0) }) { records.append($0) }
    #expect(records.map(\.messageId) == ["a", "b"])
    #expect(continuations == [["Bash"]])
    #expect(open?.id == "b")
    #expect(cwd == "/srv/x/Documents/G/p")
    #expect(consumed == text.utf8.count - #"{"type":"assistant","message":{"id":"c""#.utf8.count)
}

@Test func skipsLinesWithoutUsageAndToleratesOddShapes() {
    let text = [
        #"{"type":"user","message":{"role":"user","content":"plain string content"}}"#,
        // "usage" only inside a tool input: decoded, but there is no message.usage.
        #"{"type":"assistant","message":{"id":"x","model":"claude-opus-5-5","content":[{"type":"tool_use","name":"Edit","input":{"usage":{"input_tokens":999}}}]}}"#,
        #"not json at all "usage": "#,
        "",
        #"{"type":"assistant","timestamp":"2026-10-23T09:12:34.567Z","message":{"id":"y","model":"<synthetic>","content":"oops","usage":{"input_tokens":0,"output_tokens":0}}}"#,
    ].joined(separator: "\n") + "\n"
    var open: OpenResponse?
    var records: [UsageRecord] = []
    UsageLogParser.parse(Data(text.utf8), open: &open) { records.append($0) }
    #expect(records.count == 1)
    #expect(records.first?.model == "<synthetic>")
    #expect(records.first?.pricing == nil)
    #expect(records.first?.cost == 0)
}

@Test func chunkedFileReadingMatchesWholeFileParsing() throws {
    var text = ""
    for i in 0..<200 {
        text += line(id: "m\(i / 3)", input: i / 3, output: 1 + i) // three lines per response, output growing
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-parser-\(UUID().uuidString).jsonl")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    var reference: [String] = []
    var open: OpenResponse?
    UsageLogParser.parse(Data(text.utf8), open: &open) { if !$0.isCorrection { reference.append($0.messageId ?? "") } }
    #expect(reference.count == 67)

    for chunkSize in [1, 7, 64, 333, 1 << 20] {
        var cursor = UsageLogCursor()
        var ids: [String] = []
        let read = UsageLogParser.parseFile(atPath: url.path, cursor: &cursor, chunkSize: chunkSize) {
            if !$0.isCorrection { ids.append($0.messageId ?? "") }
        }
        #expect(ids == reference, "chunk \(chunkSize)")
        #expect(read == UInt64(text.utf8.count))
        #expect(cursor.offset == UInt64(text.utf8.count))
    }

    // Resuming from a cursor in the middle of a response doesn't count it twice.
    var cursor = UsageLogCursor()
    var firstHalf = 0
    let half = Data(text.utf8).prefix(text.utf8.count / 2)
    try half.write(to: url)
    UsageLogParser.parseFile(atPath: url.path, cursor: &cursor) { if !$0.isCorrection { firstHalf += 1 } }
    try Data(text.utf8).write(to: url)
    var secondHalf = 0
    UsageLogParser.parseFile(atPath: url.path, cursor: &cursor) { if !$0.isCorrection { secondHalf += 1 } }
    #expect(firstHalf + secondHalf == 67)
}

/// Claude Code streams a response over several lines: `output_tokens` grows and only the last
/// line has the final count. Summing every record must give the final usage, as one call.
@Test func streamedResponseCountsItsFinalUsageOnce() {
    let tool = #"{"type":"tool_use","name":"Bash","input":{}}"#
    let text = line(id: "s", output: 1) + line(id: "s", output: 40)
        + line(id: "s", block: tool, output: 300) + line(id: "t", output: 7)
    var open: OpenResponse?
    var records: [UsageRecord] = []
    var continuations: [[String]] = []
    UsageLogParser.parse(Data(text.utf8), open: &open,
                         onContinuation: { continuations.append($0) }) { records.append($0) }

    let calls = records.filter { !$0.isCorrection }
    #expect(calls.map(\.messageId) == ["s", "t"])
    let s = records.filter { $0.messageId == "s" }
    #expect(s.reduce(0) { $0 + $1.usage.outputTokens } == 300)
    #expect(s.reduce(0) { $0 + $1.usage.inputTokens } == 10)
    let final = TokenUsage(inputTokens: 10, outputTokens: 300, cacheWriteTokens: 0, cacheReadTokens: 0)
    #expect(abs(s.reduce(0.0) { $0 + $1.cost } - final.cost(for: "claude-sonnet-5-5")) < 1e-12)
    #expect(s.allSatisfy { $0.timestamp == s.first?.timestamp })
    #expect(continuations == [[], ["Bash"]])
}

/// The same response split between two reads (a line still being written) ends with the same
/// totals as one read, and a stale line with less output is ignored.
@Test func streamedResponseSplitAcrossReadsKeepsFinalUsage() {
    let first = line(id: "s", output: 1) + line(id: "s", output: 40)
    let second = line(id: "s", output: 300) + line(id: "s", output: 20)
    var open: OpenResponse?
    var output = 0, calls = 0
    for chunk in [first, second] {
        UsageLogParser.parse(Data(chunk.utf8), open: &open) { r in
            output += r.usage.outputTokens
            if !r.isCorrection { calls += 1 }
        }
    }
    #expect(output == 300)
    #expect(calls == 1)
    #expect(open?.usage.outputTokens == 300)
}

@Test func fileReadingReportsOnlyTheFirstCwdWhateverTheChunks() throws {
    // A line far longer than the chunks, then a cd into another folder.
    let long = String(repeating: "x", count: 5_000)
    let text = #"{"type":"user","cwd":"/a/first","message":{"content":"\#(long)"}}"# + "\n"
        + #"{"type":"user","cwd":"/a/second","message":{"content":"short"}}"# + "\n"
        + line(id: "m1", input: 1, output: 2)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-cwd-\(UUID().uuidString).jsonl")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    for chunkSize in [16, 333, 4_096, 1 << 20] {
        var cursor = UsageLogCursor()
        var cwds: [String] = []
        var records = 0
        UsageLogParser.parseFile(atPath: url.path, cursor: &cursor, chunkSize: chunkSize,
                                 onCwd: { cwds.append($0) }) { _ in records += 1 }
        #expect(cwds == ["/a/first"], "chunk \(chunkSize)")
        #expect(records == 1)
        #expect(cursor.offset == UInt64(text.utf8.count))
    }
}
