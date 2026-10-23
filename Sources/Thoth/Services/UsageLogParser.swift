// Sources/Thoth/Services/UsageLogParser.swift
import Foundation

/// One billable API response read from a Claude Code JSONL transcript.
struct UsageRecord {
    let messageId: String?
    let model: String
    /// nil for models without known rates (e.g. `<synthetic>`); such records cost nothing.
    let pricing: ModelPricing?
    let usage: TokenUsage
    let timestamp: Date?
    let isAssistant: Bool
    let toolNames: [String]

    var cost: Double { pricing.map(usage.cost(with:)) ?? 0 }
}

/// Read position in one JSONL file, carried across incremental reads.
struct UsageLogCursor {
    /// Byte offset just past the last complete line consumed.
    var offset: UInt64 = 0
    /// Message id of the last usage line seen; see `UsageLogParser.parse`.
    var lastMessageId: String?
}

enum UsageLogParser {
    /// Parses the complete lines of `data`. Bytes after the last newline are a line Claude Code is
    /// still writing; they are not consumed so the next read starts at the beginning of that line.
    ///
    /// Claude Code writes one JSONL line per content block (thinking, text, tool_use…) and repeats
    /// the response's `message.id` and full `usage` on each of them, always on consecutive lines.
    /// Only the first line of each response is reported to `onRecord`; tool names found on the
    /// following lines of the same response go to `onContinuation`. `lastMessageId` carries that
    /// state across calls so a response split between two reads is still counted once.
    ///
    /// Only lines containing a `"usage":` key are decoded (plus the first line with a `"cwd":`
    /// key when `onCwd` is set); user turns and tool results are skipped without JSON parsing.
    /// Thread-safe: no shared mutable state. Returns the bytes consumed.
    @discardableResult
    static func parse(
        _ data: Data,
        lastMessageId: inout String?,
        onCwd: ((String) -> Void)? = nil,
        onContinuation: ((_ toolNames: [String]) -> Void)? = nil,
        onRecord: (UsageRecord) -> Void
    ) -> Int {
        var state = ParseState(lastMessageId: lastMessageId, wantCwd: onCwd != nil)
        let consumed = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
            var lineStart = 0
            while lineStart < raw.count,
                  let nl = memchr(base + lineStart, 0x0A, raw.count - lineStart) {
                let lineEnd = base.distance(to: UnsafeRawPointer(nl))
                handleLine(UnsafeRawBufferPointer(start: base + lineStart, count: lineEnd - lineStart),
                           state: &state, onCwd: onCwd, onContinuation: onContinuation, onRecord: onRecord)
                lineStart = lineEnd + 1
            }
            return lineStart
        }
        lastMessageId = state.lastMessageId
        return consumed
    }

    /// Reads `path` from `cursor.offset` to the end in fixed-size chunks (memory stays bounded by
    /// the chunk size plus the longest line, whatever the file size) and parses every complete
    /// line, advancing `cursor`. Returns the number of bytes read, or nil if the file can't be read.
    @discardableResult
    static func parseFile(
        atPath path: String,
        cursor: inout UsageLogCursor,
        chunkSize: Int = 4 << 20,
        onCwd: ((String) -> Void)? = nil,
        onContinuation: ((_ toolNames: [String]) -> Void)? = nil,
        onRecord: (UsageRecord) -> Void
    ) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: cursor.offset)) != nil else { return nil }

        var bytesRead: UInt64 = 0
        var carry = Data()
        var reachedEnd = false
        while !reachedEnd {
            // FileHandle hands back autoreleased buffers; drain them per chunk, or a whole file
            // accumulates until the caller's pool pops.
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                bytesRead += UInt64(chunk.count)
                let buffer: Data
                if carry.isEmpty {
                    buffer = chunk
                } else {
                    carry.append(chunk)
                    buffer = carry
                }
                let consumed = parse(buffer, lastMessageId: &cursor.lastMessageId, onCwd: onCwd,
                                     onContinuation: onContinuation, onRecord: onRecord)
                cursor.offset += UInt64(consumed)
                carry = consumed == buffer.count ? Data() : Data(buffer.dropFirst(consumed))
            }
        }
        return bytesRead
    }

    // MARK: - Line handling

    private struct ParseState {
        var lastMessageId: String?
        var wantCwd: Bool
        let decoder = JSONDecoder()
        var pricingCache: [String: ModelPricing?] = [:]
    }

    private static let usageKey = Array(#""usage":"#.utf8)
    private static let cwdKey = Array(#""cwd":"#.utf8)

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress, line.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, line.count, $0.baseAddress!, needle.count) != nil }
    }

    private static func handleLine(
        _ line: UnsafeRawBufferPointer,
        state: inout ParseState,
        onCwd: ((String) -> Void)?,
        onContinuation: ((_ toolNames: [String]) -> Void)?,
        onRecord: (UsageRecord) -> Void
    ) {
        guard line.count > 2, let base = line.baseAddress else { return }
        let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)

        if state.wantCwd, contains(line, cwdKey),
           let cwd = (try? state.decoder.decode(CwdLine.self, from: bytes))?.cwd {
            onCwd?(cwd)
            state.wantCwd = false
        }

        guard contains(line, usageKey),
              let entry = try? state.decoder.decode(LogLine.self, from: bytes),
              let message = entry.message,
              let model = message.model,
              let usage = message.usage else { return }

        let toolNames = message.content?.compactMap { $0.type == "tool_use" ? $0.name : nil } ?? []

        if let id = message.id, id == state.lastMessageId {
            onContinuation?(toolNames)
            return
        }
        state.lastMessageId = message.id

        let pricing: ModelPricing?
        if let cached = state.pricingCache[model] {
            pricing = cached
        } else {
            pricing = ModelPricing.forModel(model)
            state.pricingCache[model] = pricing
        }

        onRecord(UsageRecord(
            messageId: message.id,
            model: model,
            pricing: pricing,
            usage: usage,
            timestamp: entry.timestamp.flatMap(parseTimestamp),
            isAssistant: entry.type == "assistant",
            toolNames: toolNames
        ))
    }

    // MARK: - Line schema (only the fields Thoth reads)

    private struct CwdLine: Decodable {
        let cwd: String?
    }

    private struct LogLine: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: TokenUsage?
        let content: [ContentBlock]?

        enum CodingKeys: String, CodingKey { case id, model, usage, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            usage = try? c.decodeIfPresent(TokenUsage.self, forKey: .usage)
            // User turns can carry a plain string here; only block arrays matter.
            content = try? c.decodeIfPresent([ContentBlock].self, forKey: .content)
        }
    }

    private struct ContentBlock: Decodable {
        let type: String?
        let name: String?
    }

    // MARK: - Timestamps

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Fast path for the `YYYY-MM-DDTHH:MM:SS.sssZ` form Claude Code writes (JavaScript's
    /// `toISOString`); anything else goes through ISO8601DateFormatter.
    static func parseTimestamp(_ string: String) -> Date? {
        var s = string
        let fast: Date? = s.withUTF8 { u -> Date? in
            guard u.count == 24, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54, u[13] == 0x3A,
                  u[16] == 0x3A, u[19] == 0x2E, u[23] == 0x5A else { return nil }
            func num(_ from: Int, _ len: Int) -> Int? {
                var value = 0
                for i in from..<(from + len) {
                    let d = Int(u[i]) - 48
                    guard d >= 0 && d <= 9 else { return nil }
                    value = value * 10 + d
                }
                return value
            }
            guard let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
                  let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
                  let millis = num(20, 3),
                  (1...12).contains(month), (1...31).contains(day),
                  hour < 24, minute < 60, second < 61 else { return nil }
            // Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's days_from_civil).
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (month + 9) % 12
            let doy = (153 * mp + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            let seconds = Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + Double(millis) / 1_000
            return Date(timeIntervalSince1970: seconds)
        }
        return fast ?? isoFormatter.date(from: string)
    }
}
