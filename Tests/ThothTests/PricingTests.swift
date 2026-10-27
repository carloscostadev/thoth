// Tests/ThothTests/PricingTests.swift
import Testing
@testable import Thoth

/// Expected $/MTok from https://platform.claude.com/docs/en/about-claude/pricing (checked 2026-10-23):
/// input, output, 5m cache write, 1h cache write, cache read.
private let officialRates: [(id: String, rates: TokenRates)] = [
    ("claude-fable-5-1", TokenRates(input: 10, output: 50, cacheWrite5m: 12.50, cacheWrite1h: 20, cacheRead: 0.25)),
    ("claude-fable-5", TokenRates(input: 10, output: 50, cacheWrite5m: 12.50, cacheWrite1h: 20, cacheRead: 1.00)),
    ("claude-mythos-5-1", TokenRates(input: 10, output: 50, cacheWrite5m: 12.50, cacheWrite1h: 20, cacheRead: 0.25)),
    ("claude-mythos-5", TokenRates(input: 10, output: 50, cacheWrite5m: 12.50, cacheWrite1h: 20, cacheRead: 1.00)),
    ("claude-opus-5-5", TokenRates(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20)),
    ("claude-opus-5", TokenRates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50)),
    ("claude-opus-4-8", TokenRates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50)),
    ("claude-opus-4-7", TokenRates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50)),
    ("claude-opus-4-6", TokenRates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50)),
    ("claude-opus-4-5-20251101", TokenRates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50)),
    ("claude-opus-4-1-20250805", TokenRates(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.50)),
    ("claude-opus-4-20250514", TokenRates(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.50)),
    ("claude-sonnet-5-5", TokenRates(input: 2, output: 10, cacheWrite5m: 2.50, cacheWrite1h: 4, cacheRead: 0.10)),
    ("claude-sonnet-5", TokenRates(input: 2, output: 10, cacheWrite5m: 2.50, cacheWrite1h: 4, cacheRead: 0.20)),
    ("claude-sonnet-4-6", TokenRates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)),
    ("claude-sonnet-4-5-20250929", TokenRates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)),
    ("claude-sonnet-4-20250514", TokenRates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)),
    ("claude-haiku-5-5", TokenRates(input: 0.10, output: 0.50, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01)),
    ("claude-haiku-4-5-20251001", TokenRates(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.10)),
    ("claude-3-5-haiku-20241022", TokenRates(input: 0.80, output: 4, cacheWrite5m: 1, cacheWrite1h: 1.60, cacheRead: 0.08)),
]

@Test(arguments: officialRates.map(\.id))
func officialRatesPerModel(id: String) throws {
    let expected = try #require(officialRates.first { $0.id == id }).rates
    let pricing = try #require(ModelPricing.forModel(id))
    #expect(pricing.rates == expected)
}

@Test func everyFamilyIsPriced() {
    for family in ModelFamily.allCases {
        #expect(ModelPricing.all.contains { $0.family == family }, "\(family) has no rates")
    }
}

@Test func opus45To48AreNotPricedAsOpus4() {
    // Regression: the old table charged every claude-opus-4* at Opus 4 rates ($15/$75), ~3x too much.
    for id in ["claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8"] {
        let pricing = ModelPricing.forModel(id)
        #expect(pricing?.inputPerMillion == 5)
        #expect(pricing?.outputPerMillion == 25)
    }
}

@Test func claude5ModelsHaveNonZeroCost() {
    let usage = TokenUsage(inputTokens: 1_000, outputTokens: 1_000, cacheWriteTokens: 0, cacheReadTokens: 0)
    for id in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5"] {
        #expect(usage.cost(for: id) > 0, "\(id) priced at $0")
    }
}

@Test func providerAndSnapshotDecorationsAreIgnored() {
    let ids = [
        "claude-sonnet-4-6",
        "anthropic.claude-sonnet-4-6",
        "us.anthropic.claude-sonnet-4-6-v1:0",
        "claude-sonnet-4-6@20260101",
        "claude-sonnet-4-6[1m]",
        "CLAUDE-SONNET-4-6",
        "claude-sonnet-4-6-latest",
    ]
    for id in ids {
        #expect(ModelIdentifier.parse(id) == ModelIdentifier(family: .sonnet, major: 4, minor: 6), "\(id)")
    }
    #expect(ModelIdentifier.parse("claude-3-7-sonnet-20250219") == ModelIdentifier(family: .sonnet, major: 3, minor: 7))
    #expect(ModelIdentifier.parse("claude-opus-4-20250514") == ModelIdentifier(family: .opus, major: 4, minor: 0))
}

@Test func unknownVersionsFallBackWithinFamily() {
    // Newer than the table: newest known version of the family that isn't newer.
    #expect(ModelPricing.forModel("claude-opus-5-6")?.rates == ModelPricing.forModel("claude-opus-5-5")?.rates)
    #expect(ModelPricing.forModel("claude-opus-6-20270101")?.rates == ModelPricing.forModel("claude-opus-5-5")?.rates)
    #expect(ModelPricing.forModel("claude-sonnet-6")?.rates == ModelPricing.forModel("claude-sonnet-5-5")?.rates)
    #expect(ModelPricing.forModel("claude-haiku-6")?.rates == ModelPricing.forModel("claude-haiku-5-5")?.rates)
    #expect(ModelPricing.forModel("claude-fable-5-2")?.rates == ModelPricing.forModel("claude-fable-5-1")?.rates)
    #expect(ModelPricing.forModel("claude-mythos-6")?.rates == ModelPricing.forModel("claude-mythos-5-1")?.rates)
    // In-between versions take the closest older one.
    #expect(ModelPricing.forModel("claude-opus-4-9")?.rates == ModelPricing.forModel("claude-opus-4-8")?.rates)
    #expect(ModelPricing.forModel("claude-opus-4-2")?.rates == ModelPricing.forModel("claude-opus-4-1")?.rates)
    // Older than the table: oldest known version of the family.
    #expect(ModelPricing.forModel("claude-3-opus-20240229")?.rates == ModelPricing.forModel("claude-opus-4")?.rates)
    #expect(ModelPricing.forModel("claude-3-5-sonnet-20241022")?.rates == ModelPricing.forModel("claude-sonnet-4")?.rates)
    #expect(ModelPricing.forModel("claude-3-haiku-20240307")?.rates == ModelPricing.forModel("claude-3-5-haiku")?.rates)
}

@Test(arguments: officialRates.map(\.id))
func listedVersionsAreExactMatches(id: String) throws {
    let match = try #require(ModelPricing.match(for: id))
    #expect(match.isExact)
    #expect(ModelUsageEntry(modelId: ModelUsageEntry.key(for: id)).pricingNote == nil)
}

@Test func decoratedIdsOfListedVersionsAreExact() {
    for id in ["us.anthropic.claude-sonnet-4-6-v1:0", "claude-opus-4-1@20250805", "claude-opus-4-6[1m]",
               "claude-sonnet-4-5-20250929", "claude-sonnet-5-5-latest"] {
        #expect(ModelPricing.match(for: id)?.isExact == true, "\(id)")
    }
}

@Test func fallbackPricesAreFlaggedWithTheirReference() {
    let cases: [(id: String, reference: String)] = [
        ("claude-opus-5-6", "opus-5-5"),
        ("claude-opus-6-20270101", "opus-5-5"),
        ("claude-sonnet-6", "sonnet-5-5"),
        ("claude-fable-5-2", "fable-5-1"),
        ("claude-opus-4-9", "opus-4-8"),
        ("claude-opus-4-2", "opus-4-1"),
        ("claude-3-opus-20240229", "opus-4"),
        ("claude-3-5-sonnet-20241022", "sonnet-4"),
        ("claude-3-haiku-20240307", "haiku-3-5"),
    ]
    for (id, reference) in cases {
        let match = ModelPricing.match(for: id)
        #expect(match?.isExact == false, "\(id)")
        #expect(match?.referenceName == reference, "\(id)")
    }
    #expect(ModelPricing.match(for: "<synthetic>") == nil)
}

@Test func matchUsesTheSameRatesAsForModel() {
    let ids = officialRates.map(\.id) + ["claude-opus-5-6", "claude-3-opus-20240229", "claude-haiku-6", "claude-mythos-6"]
    for id in ids {
        #expect(ModelPricing.match(for: id)?.pricing.rates == ModelPricing.forModel(id)?.rates, "\(id)")
    }
    // Costs are unchanged by the flag: a fallback model costs exactly what its reference costs.
    let usage = TokenUsage(inputTokens: 12_345, outputTokens: 6_789, cacheWriteTokens: 1_000, cacheReadTokens: 50_000)
    #expect(usage.cost(for: "claude-opus-5-6") == usage.cost(for: "claude-opus-5-5"))
}

@Test func modelRowsExposeTheApproximatePrice() {
    var aggregator = ModelUsageAggregator()
    let usage = TokenUsage(inputTokens: 100, outputTokens: 100, cacheWriteTokens: 0, cacheReadTokens: 0)
    aggregator.add(usage: usage, model: "claude-opus-5-6-20270101")
    aggregator.add(usage: usage, model: "claude-sonnet-5-5")
    let rows = Dictionary(uniqueKeysWithValues: aggregator.entries.map { ($0.modelId, $0) })

    let future = rows["claude-opus-5-6"]
    #expect(future?.hasApproximatePricing == true)
    #expect(future?.pricingNote?.contains("opus-5-5 rates") == true)
    #expect(rows["claude-sonnet-5-5"]?.hasApproximatePricing == false)
    #expect(rows["claude-sonnet-5-5"]?.pricingNote == nil)
}

@Test func claudeModelsOfUnknownFamiliesGetARowWithoutPrice() {
    #expect(ModelIdentifier.unknownClaudeModelKey("claude-nova-1-0") == "claude-nova-1-0")
    #expect(ModelIdentifier.unknownClaudeModelKey("us.anthropic.claude-nova-1-0-v1:0") == "claude-nova-1-0")
    #expect(ModelIdentifier.unknownClaudeModelKey("claude-nova-1-0-20290101") == "claude-nova-1-0")
    // Known families have their canonical key; non-Claude ids are not counted at all.
    for id in ["claude-opus-6", "<synthetic>", "other-vendor-model", "gpt-4o", "", "claude-"] {
        #expect(ModelIdentifier.unknownClaudeModelKey(id) == nil, "\(id)")
    }
    #expect(ModelUsageEntry.key(for: "us.anthropic.claude-nova-1-0-v1:0") == "claude-nova-1-0")

    var aggregator = ModelUsageAggregator()
    let usage = TokenUsage(inputTokens: 100, outputTokens: 100, cacheWriteTokens: 0, cacheReadTokens: 0)
    aggregator.add(usage: usage, model: "claude-nova-1-0")
    let row = aggregator.entries.first
    #expect(row?.totalCost == 0 && row?.totalTokens == 200)
    #expect(row?.hasNoKnownPrice == true && row?.hasApproximatePricing == false)
    #expect(row?.pricingNote?.contains("No known price") == true)
    #expect(ModelUsageEntry(modelId: "claude-opus-5-5").hasNoKnownPrice == false)
}

@Test func unknownModelsReturnNil() {
    for id in ["unknown-model", "<synthetic>", "claude-instant-1.2", "claude-2.1", "gpt-4o", "", "claude-", "claude-opus"] {
        #expect(ModelPricing.forModel(id) == nil, "\(id)")
    }
}

@Test func costCalculation() throws {
    let pricing = try #require(ModelPricing.forModel("claude-opus-4-6"))
    let cost = pricing.calculateCost(
        inputTokens: 1_000_000,
        outputTokens: 1_000_000,
        cacheReadTokens: 1_000_000,
        cacheWriteTokens: 1_000_000
    )
    // 5 + 25 + 0.5 + 6.25 = 36.75
    #expect(abs(cost - 36.75) < 0.0001)
}

@Test func oneHourCacheWritesUseTheirOwnRate() throws {
    let pricing = try #require(ModelPricing.forModel("claude-opus-5-5"))
    let cost = pricing.calculateCost(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                                     cacheWriteTokens: 3_000_000, cacheWrite1hTokens: 1_000_000)
    // 2M × $5 (5m) + 1M × $8 (1h) = 18
    #expect(abs(cost - 18) < 0.0001)
    // A 1h count larger than the total is clamped, never negative 5m tokens.
    let clamped = pricing.calculateCost(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                                        cacheWriteTokens: 1_000_000, cacheWrite1hTokens: 5_000_000)
    #expect(abs(clamped - 8) < 0.0001)
}

@Test func haiku55LongPromptTier() throws {
    let pricing = try #require(ModelPricing.forModel("claude-haiku-5-5"))
    // Prompt = input + cache read + cache write = exactly 100,000 → standard rates.
    let atThreshold = pricing.calculateCost(inputTokens: 40_000, outputTokens: 1_000_000,
                                            cacheReadTokens: 50_000, cacheWriteTokens: 10_000)
    // 0.04 × 0.10 + 1 × 0.50 + 0.05 × 0.01 + 0.01 × 0.125
    #expect(abs(atThreshold - (0.004 + 0.5 + 0.0005 + 0.00125)) < 1e-9)
    // One token over → every token of the request, output included, at the long-prompt rates.
    let over = pricing.calculateCost(inputTokens: 40_001, outputTokens: 1_000_000,
                                     cacheReadTokens: 50_000, cacheWriteTokens: 10_000)
    #expect(abs(over - (0.040001 * 0.50 + 2.50 + 0.05 * 0.05 + 0.01 * 0.625)) < 1e-9)
    // Other models have no tier.
    #expect(ModelPricing.forModel("claude-haiku-4-5")?.longPrompt == nil)
}
