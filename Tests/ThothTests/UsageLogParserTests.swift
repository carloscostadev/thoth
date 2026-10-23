// Tests/ThothTests/UsageLogParserTests.swift
import Foundation
import Testing
@testable import Thoth

private func line(id: String, model: String = "claude-sonnet-5-5", block: String = #"{"type":"text","text":"hi"}"#,
                  input: Int = 10, ts: String = "2026-10-23T09:12:34.567Z") -> String {
    #"{"type":"assistant","cwd":"/srv/x/Documents/G/p","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","content":[\#(block)],"usage":{"input_tokens":\#(input),"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
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
    var last: String?
    var records: [UsageRecord] = []
    var continuations: [[String]] = []
    var cwd: String?
    let consumed = UsageLogParser.parse(data, lastMessageId: &last, onCwd: { cwd = $0 },
                                        onContinuation: { continuations.append($0) }) { records.append($0) }
    #expect(records.map(\.messageId) == ["a", "b"])
    #expect(continuations == [["Bash"]])
    #expect(last == "b")
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
        #"{"type":"assistant","message":{"id":"y","model":"<synthetic>","content":"oops","usage":{"input_tokens":0,"output_tokens":0}}}"#,
    ].joined(separator: "\n") + "\n"
    var last: String?
    var records: [UsageRecord] = []
    UsageLogParser.parse(Data(text.utf8), lastMessageId: &last) { records.append($0) }
    #expect(records.count == 1)
    #expect(records.first?.model == "<synthetic>")
    #expect(records.first?.pricing == nil)
    #expect(records.first?.cost == 0)
}

@Test func chunkedFileReadingMatchesWholeFileParsing() throws {
    var text = ""
    for i in 0..<200 {
        text += line(id: "m\(i / 3)", input: i) // three lines per response
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-parser-\(UUID().uuidString).jsonl")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    var reference: [String] = []
    var last: String?
    UsageLogParser.parse(Data(text.utf8), lastMessageId: &last) { reference.append($0.messageId ?? "") }
    #expect(reference.count == 67)

    for chunkSize in [1, 7, 64, 333, 1 << 20] {
        var cursor = UsageLogCursor()
        var ids: [String] = []
        let read = UsageLogParser.parseFile(atPath: url.path, cursor: &cursor, chunkSize: chunkSize) {
            ids.append($0.messageId ?? "")
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
    UsageLogParser.parseFile(atPath: url.path, cursor: &cursor) { _ in firstHalf += 1 }
    try Data(text.utf8).write(to: url)
    var secondHalf = 0
    UsageLogParser.parseFile(atPath: url.path, cursor: &cursor) { _ in secondHalf += 1 }
    #expect(firstHalf + secondHalf == 67)
}
