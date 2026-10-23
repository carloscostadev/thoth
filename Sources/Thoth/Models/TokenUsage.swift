// Sources/Thoth/Models/TokenUsage.swift
import Foundation

struct TokenUsage: Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    /// Total cache creation tokens (5-minute + 1-hour).
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    /// Part of `cacheWriteTokens` written to the 1-hour cache, billed at a higher rate.
    let cacheWrite1hTokens: Int

    init(inputTokens: Int, outputTokens: Int, cacheWriteTokens: Int, cacheReadTokens: Int,
         cacheWrite1hTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    /// Field-by-field difference, e.g. the growth of a streamed response's usage.
    func subtracting(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: inputTokens - other.inputTokens,
                   outputTokens: outputTokens - other.outputTokens,
                   cacheWriteTokens: cacheWriteTokens - other.cacheWriteTokens,
                   cacheReadTokens: cacheReadTokens - other.cacheReadTokens,
                   cacheWrite1hTokens: cacheWrite1hTokens - other.cacheWrite1hTokens)
    }

    func cost(for modelId: String) -> Double {
        guard let pricing = ModelPricing.forModel(modelId) else { return 0 }
        return cost(with: pricing)
    }

    func cost(with pricing: ModelPricing) -> Double {
        pricing.calculateCost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            cacheWrite1hTokens: cacheWrite1hTokens
        )
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheWriteTokens = "cache_creation_input_tokens"
        case cacheReadTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
    }

    private enum CacheCreationKeys: String, CodingKey {
        case oneHour = "ephemeral_1h_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        let creation = try? c.nestedContainer(keyedBy: CacheCreationKeys.self, forKey: .cacheCreation)
        cacheWrite1hTokens = (try? creation?.decodeIfPresent(Int.self, forKey: .oneHour)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        var creation = c.nestedContainer(keyedBy: CacheCreationKeys.self, forKey: .cacheCreation)
        try creation.encode(cacheWrite1hTokens, forKey: .oneHour)
    }
}

struct ModelUsageEntry: Identifiable {
    /// Canonical model id (`claude-opus-4-5`), so dated and undated ids share one row.
    let modelId: String
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0
    var sessionCount: Int = 0
    /// Summed per request: tiered prices (Haiku 5.5) can't be recomputed from totals.
    var totalCost: Double = 0

    var id: String { modelId }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens
    }

    var family: ModelFamily? { ModelIdentifier.parse(modelId)?.family }

    var displayName: String {
        if modelId.hasPrefix("claude-") {
            return String(modelId.dropFirst("claude-".count))
        }
        return modelId
    }

    /// Row key for a raw model id from the logs.
    static func key(for model: String) -> String {
        ModelIdentifier.parse(model)?.canonical ?? model
    }
}

struct ModelUsageAggregator {
    private(set) var entries: [ModelUsageEntry] = []
    /// Raw id -> row key, so a scan over many files parses each distinct id once.
    private var keys: [String: String] = [:]

    private mutating func key(for model: String) -> String {
        if let key = keys[model] { return key }
        let key = ModelUsageEntry.key(for: model)
        keys[model] = key
        return key
    }

    mutating func incrementSessionCount(for model: String) {
        let key = key(for: model)
        if let idx = entries.firstIndex(where: { $0.modelId == key }) {
            entries[idx].sessionCount += 1
        }
    }

    /// Adds a single request, priced on its own.
    mutating func add(usage: TokenUsage, model: String) {
        add(usage: usage, cost: usage.cost(for: model), model: model)
    }

    /// Adds already-priced usage (e.g. a per-file aggregate of many requests).
    mutating func add(usage: TokenUsage, cost: Double, model: String) {
        let key = key(for: model)
        let idx: Int
        if let existing = entries.firstIndex(where: { $0.modelId == key }) {
            idx = existing
        } else {
            entries.append(ModelUsageEntry(modelId: key))
            idx = entries.count - 1
        }
        entries[idx].inputTokens += usage.inputTokens
        entries[idx].outputTokens += usage.outputTokens
        entries[idx].cacheWriteTokens += usage.cacheWriteTokens
        entries[idx].cacheReadTokens += usage.cacheReadTokens
        entries[idx].totalCost += cost
    }
}
