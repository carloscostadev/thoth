// Tests/ThothTests/TokenUsageTests.swift
import Testing
import Foundation
@testable import Thoth

@Test func parseUsageFromJSON() throws {
    let json = """
    {
        "input_tokens": 100,
        "output_tokens": 200,
        "cache_creation_input_tokens": 300,
        "cache_read_input_tokens": 400
    }
    """.data(using: .utf8)!

    let usage = try JSONDecoder().decode(TokenUsage.self, from: json)
    #expect(usage.inputTokens == 100)
    #expect(usage.outputTokens == 200)
    #expect(usage.cacheWriteTokens == 300)
    #expect(usage.cacheReadTokens == 400)
    #expect(usage.cacheWrite1hTokens == 0)
}

@Test func parseOneHourCacheWritesFromJSON() throws {
    let json = """
    {"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":4,
     "cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}
    """.data(using: .utf8)!
    let usage = try JSONDecoder().decode(TokenUsage.self, from: json)
    #expect(usage.cacheWriteTokens == 300)
    #expect(usage.cacheWrite1hTokens == 200)
}

@Test func totalTokens() throws {
    let usage = TokenUsage(inputTokens: 100, outputTokens: 200, cacheWriteTokens: 300, cacheReadTokens: 400)
    #expect(usage.totalTokens == 1000)
}

@Test func costForModel() {
    let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000, cacheWriteTokens: 0, cacheReadTokens: 2_000_000)
    let cost = usage.cost(for: "claude-opus-4-6")
    // input: 5.0, output: 12.5, cacheRead: 1.0 = 18.5
    #expect(abs(cost - 18.5) < 0.01)
}

@Test func costForUnknownModelIsZero() {
    let usage = TokenUsage(inputTokens: 1_000, outputTokens: 1_000, cacheWriteTokens: 0, cacheReadTokens: 0)
    #expect(usage.cost(for: "<synthetic>") == 0)
}

@Test func modelUsageAggregation() {
    var agg = ModelUsageAggregator()
    agg.add(usage: TokenUsage(inputTokens: 100, outputTokens: 200, cacheWriteTokens: 0, cacheReadTokens: 0), model: "claude-opus-4-6")
    agg.add(usage: TokenUsage(inputTokens: 50, outputTokens: 100, cacheWriteTokens: 0, cacheReadTokens: 0), model: "claude-opus-4-6")
    agg.add(usage: TokenUsage(inputTokens: 30, outputTokens: 60, cacheWriteTokens: 0, cacheReadTokens: 0), model: "claude-sonnet-4-6")

    let opusEntry = agg.entries.first { $0.modelId.hasPrefix("claude-opus") }
    #expect(opusEntry != nil)
    #expect(opusEntry!.totalTokens == 450) // 100+200+50+100
}

@Test func datedAndUndatedIdsShareOneRow() throws {
    var agg = ModelUsageAggregator()
    let usage = TokenUsage(inputTokens: 1_000, outputTokens: 1_000, cacheWriteTokens: 0, cacheReadTokens: 0)
    agg.add(usage: usage, model: "claude-haiku-4-5-20251001")
    agg.add(usage: usage, model: "claude-haiku-4-5")
    agg.add(usage: usage, model: "claude-fable-5-1")
    agg.incrementSessionCount(for: "claude-haiku-4-5-20251001")

    #expect(agg.entries.count == 2)
    let haiku = try #require(agg.entries.first { $0.modelId == "claude-haiku-4-5" })
    #expect(haiku.displayName == "haiku-4-5")
    #expect(haiku.family == .haiku)
    #expect(haiku.sessionCount == 1)
    #expect(abs(haiku.totalCost - 2 * (0.001 * 1 + 0.001 * 5)) < 1e-9)
    let fable = try #require(agg.entries.first { $0.modelId == "claude-fable-5-1" })
    #expect(fable.displayName == "fable-5-1")
    #expect(fable.family == .fable)
}

@Test func tieredCostIsSummedPerRequest() throws {
    // Two Haiku 5.5 requests of 60k prompt tokens each stay on standard rates even though
    // their combined prompt is over the 100k threshold.
    var agg = ModelUsageAggregator()
    let usage = TokenUsage(inputTokens: 60_000, outputTokens: 0, cacheWriteTokens: 0, cacheReadTokens: 0)
    agg.add(usage: usage, model: "claude-haiku-5-5")
    agg.add(usage: usage, model: "claude-haiku-5-5")
    let entry = try #require(agg.entries.first)
    #expect(abs(entry.totalCost - 0.12 * 0.10) < 1e-9)
}
