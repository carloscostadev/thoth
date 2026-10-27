// Sources/Thoth/Models/Pricing.swift
import Foundation

enum ModelFamily: String, CaseIterable {
    case fable, mythos, opus, sonnet, haiku
}

/// A Claude model id reduced to family + version, independent of date suffixes and
/// cloud-provider decorations.
///
///   claude-opus-4-5-20251101                  -> opus 4.5
///   claude-3-5-haiku-20241022                 -> haiku 3.5   (pre-4 naming)
///   us.anthropic.claude-sonnet-4-6-v1:0       -> sonnet 4.6  (Bedrock)
///   claude-opus-4-1@20250805, claude-opus-4-6[1m] -> opus 4.1, opus 4.6
struct ModelIdentifier: Equatable {
    let family: ModelFamily
    let major: Int
    let minor: Int

    /// Stable id used to group usage of the same model: `claude-opus-4-5`, `claude-opus-5`.
    var canonical: String {
        minor == 0 ? "claude-\(family.rawValue)-\(major)" : "claude-\(family.rawValue)-\(major)-\(minor)"
    }

    static func parse(_ raw: String) -> ModelIdentifier? {
        var id = raw.lowercased()
        guard let start = id.range(of: "claude-", options: .backwards) else { return nil }
        id = String(id[start.upperBound...])
        if let cut = id.firstIndex(where: { $0 == "@" || $0 == "[" || $0 == ":" }) {
            id = String(id[..<cut])
        }

        var parts = id.split(separator: "-").map(String.init)
        // Drop trailing decorations: Bedrock "-v1", date snapshots "-20251101", "-latest".
        while let last = parts.last,
              last == "latest"
                || (last.count == 8 && last.allSatisfy(\.isNumber))
                || (last.count > 1 && last.hasPrefix("v") && last.dropFirst().allSatisfy(\.isNumber)) {
            parts.removeLast()
        }

        guard let familyIndex = parts.firstIndex(where: { ModelFamily(rawValue: $0) != nil }),
              let family = ModelFamily(rawValue: parts[familyIndex]) else { return nil }
        // New naming puts the version after the family, the pre-4 naming before it.
        let after = Array(parts[(familyIndex + 1)...])
        let before = Array(parts[..<familyIndex])
        let versionParts = after.isEmpty ? before : after
        let numbers = versionParts.prefix(2).compactMap { $0.count <= 2 ? Int($0) : nil }
        guard let major = numbers.first else { return nil }
        return ModelIdentifier(family: family, major: major, minor: numbers.count > 1 ? numbers[1] : 0)
    }

    fileprivate var versionKey: Int { major * 100 + minor }
}

/// Per-million-token rates in USD.
struct TokenRates: Equatable {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double
}

/// Rate card for one model version.
///
/// Source: Anthropic API pricing, https://platform.claude.com/docs/en/about-claude/pricing
/// (checked 2026-10-23). First-party API list prices; Bedrock / Vertex, batch, fast mode,
/// data-residency multipliers and server-tool fees are not modelled.
struct ModelPricing {
    let family: ModelFamily
    let major: Int
    let minor: Int
    let rates: TokenRates
    /// Haiku 5.5 bills the whole request at higher rates once its prompt (input + cache
    /// reads + cache writes) exceeds this many tokens.
    let longPrompt: (threshold: Int, rates: TokenRates)?

    init(_ family: ModelFamily, _ major: Int, _ minor: Int, _ rates: TokenRates,
         longPrompt: (threshold: Int, rates: TokenRates)? = nil) {
        self.family = family
        self.major = major
        self.minor = minor
        self.rates = rates
        self.longPrompt = longPrompt
    }

    var inputPerMillion: Double { rates.input }
    var outputPerMillion: Double { rates.output }
    var cacheReadPerMillion: Double { rates.cacheRead }
    var cacheWritePerMillion: Double { rates.cacheWrite5m }

    func rates(forPromptTokens promptTokens: Int) -> TokenRates {
        if let longPrompt, promptTokens > longPrompt.threshold { return longPrompt.rates }
        return rates
    }

    /// Cost of a single API request. `cacheWriteTokens` is the total cache creation;
    /// `cacheWrite1hTokens` is the part of it written to the 1-hour cache.
    func calculateCost(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        cacheWrite1hTokens: Int = 0
    ) -> Double {
        let oneHour = min(max(cacheWrite1hTokens, 0), cacheWriteTokens)
        let fiveMinute = cacheWriteTokens - oneHour
        let r = rates(forPromptTokens: inputTokens + cacheReadTokens + cacheWriteTokens)
        let total = Double(inputTokens) * r.input
            + Double(outputTokens) * r.output
            + Double(cacheReadTokens) * r.cacheRead
            + Double(fiveMinute) * r.cacheWrite5m
            + Double(oneHour) * r.cacheWrite1h
        return total / 1_000_000
    }

    private static func r(_ input: Double, _ output: Double, _ write5m: Double, _ write1h: Double,
                          _ read: Double) -> TokenRates {
        TokenRates(input: input, output: output, cacheWrite5m: write5m, cacheWrite1h: write1h, cacheRead: read)
    }

    /// Columns: input, output, 5m cache write, 1h cache write, cache read ($ / MTok).
    static let all: [ModelPricing] = [
        ModelPricing(.fable, 5, 1, r(10, 50, 12.50, 20, 0.25)),
        ModelPricing(.fable, 5, 0, r(10, 50, 12.50, 20, 1.00)),
        ModelPricing(.mythos, 5, 1, r(10, 50, 12.50, 20, 0.25)),
        ModelPricing(.mythos, 5, 0, r(10, 50, 12.50, 20, 1.00)),

        ModelPricing(.opus, 5, 5, r(4, 20, 5.00, 8, 0.20)),
        ModelPricing(.opus, 5, 0, r(5, 25, 6.25, 10, 0.50)),
        ModelPricing(.opus, 4, 8, r(5, 25, 6.25, 10, 0.50)),
        ModelPricing(.opus, 4, 7, r(5, 25, 6.25, 10, 0.50)),
        ModelPricing(.opus, 4, 6, r(5, 25, 6.25, 10, 0.50)),
        ModelPricing(.opus, 4, 5, r(5, 25, 6.25, 10, 0.50)),
        ModelPricing(.opus, 4, 1, r(15, 75, 18.75, 30, 1.50)),
        ModelPricing(.opus, 4, 0, r(15, 75, 18.75, 30, 1.50)),

        ModelPricing(.sonnet, 5, 5, r(2, 10, 2.50, 4, 0.10)),
        ModelPricing(.sonnet, 5, 0, r(2, 10, 2.50, 4, 0.20)),
        ModelPricing(.sonnet, 4, 6, r(3, 15, 3.75, 6, 0.30)),
        ModelPricing(.sonnet, 4, 5, r(3, 15, 3.75, 6, 0.30)),
        ModelPricing(.sonnet, 4, 0, r(3, 15, 3.75, 6, 0.30)),

        ModelPricing(.haiku, 5, 5, r(0.10, 0.50, 0.125, 0.20, 0.01),
                     longPrompt: (100_000, r(0.50, 2.50, 0.625, 1.00, 0.05))),
        ModelPricing(.haiku, 4, 5, r(1, 5, 1.25, 2, 0.10)),
        ModelPricing(.haiku, 3, 5, r(0.80, 4, 1.00, 1.60, 0.08)),
    ]

    /// Exact version when known. Otherwise the newest known version of the same family that is
    /// not newer than the requested one (e.g. a future `opus-5-6` uses Opus 5.5 rates), or the
    /// oldest known version for ids older than the table. Ids without a known family return nil.
    static func forModel(_ modelId: String) -> ModelPricing? {
        match(for: modelId)?.pricing
    }

    /// The rate card `forModel` uses, and whether it is the model's own or a reference taken
    /// from another version of the family.
    static func match(for modelId: String) -> PricingMatch? {
        guard let id = ModelIdentifier.parse(modelId), let family = byFamily[id.family],
              let pricing = family.first(where: { $0.versionKey <= id.versionKey }) ?? family.last else { return nil }
        return PricingMatch(pricing: pricing, isExact: pricing.versionKey == id.versionKey)
    }

    /// Canonical id of this rate card's version: `claude-opus-5-5`.
    var canonicalId: String { ModelIdentifier(family: family, major: major, minor: minor).canonical }

    /// Newest version first.
    private static let byFamily: [ModelFamily: [ModelPricing]] =
        Dictionary(grouping: all, by: \.family).mapValues { $0.sorted { $0.versionKey > $1.versionKey } }

    private var versionKey: Int { major * 100 + minor }
}

/// Which rate card prices a model id.
struct PricingMatch {
    let pricing: ModelPricing
    /// False when the table has no rates for the id's version and those of another version of
    /// the same family are used: the cost is an approximation.
    let isExact: Bool

    /// Id of the version whose rates are used, without the `claude-` prefix: `opus-5-5`.
    var referenceName: String { String(pricing.canonicalId.dropFirst("claude-".count)) }
}
