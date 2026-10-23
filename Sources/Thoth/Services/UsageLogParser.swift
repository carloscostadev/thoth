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
    /// Returns the bytes consumed.
    @discardableResult
    static func parse(
        _ data: Data,
        lastMessageId: inout String?,
        onCwd: ((String) -> Void)? = nil,
        onContinuation: ((_ toolNames: [String]) -> Void)? = nil,
        onRecord: (UsageRecord) -> Void
    ) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var pricingCache: [String: ModelPricing?] = [:]
        var wantCwd = onCwd != nil

        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }

            if wantCwd, let cwd = json["cwd"] as? String {
                onCwd?(cwd)
                wantCwd = false
            }

            guard let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usageDict = message["usage"] as? [String: Any] else { continue }

            let messageId = message["id"] as? String
            let toolNames = (message["content"] as? [[String: Any]])?.compactMap { block -> String? in
                block["type"] as? String == "tool_use" ? block["name"] as? String : nil
            } ?? []

            if let messageId, messageId == lastMessageId {
                onContinuation?(toolNames)
                continue
            }
            lastMessageId = messageId

            let pricing: ModelPricing?
            if let cached = pricingCache[model] {
                pricing = cached
            } else {
                pricing = ModelPricing.forModel(model)
                pricingCache[model] = pricing
            }

            let usage = TokenUsage(
                inputTokens: usageDict["input_tokens"] as? Int ?? 0,
                outputTokens: usageDict["output_tokens"] as? Int ?? 0,
                cacheWriteTokens: usageDict["cache_creation_input_tokens"] as? Int ?? 0,
                cacheReadTokens: usageDict["cache_read_input_tokens"] as? Int ?? 0,
                cacheWrite1hTokens: (usageDict["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0
            )
            let timestamp = (json["timestamp"] as? String).flatMap(isoFormatter.date(from:))

            onRecord(UsageRecord(
                messageId: messageId,
                model: model,
                pricing: pricing,
                usage: usage,
                timestamp: timestamp,
                isAssistant: json["type"] as? String == "assistant",
                toolNames: toolNames
            ))
        }
        return complete.count
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
