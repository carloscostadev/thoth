// Sources/Thoth/Models/ActivityCategory.swift
import Foundation
import SwiftUI

enum ActivityCategory: String, CaseIterable, Identifiable {
    case conversation = "Conversation"
    case coding = "Coding"
    case exploration = "Exploration"
    case terminal = "Terminal"
    case planning = "Planning"
    case design = "Design"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .conversation: return .blue
        case .coding: return .green
        case .exploration: return .purple
        case .terminal: return .orange
        case .planning: return .yellow
        case .design: return .pink
        }
    }

    /// Classify a set of tool names from an assistant message into a category.
    /// If no tools are used, it's a conversation turn.
    static func classify(tools: [String]) -> ActivityCategory {
        if tools.isEmpty { return .conversation }

        // Priority-based classification
        let toolSet = Set(tools)

        if !toolSet.isDisjoint(with: codingTools) { return .coding }

        // Design: MCP figma tools, frontend-design skill
        if tools.contains(where: { name in designKeywords.contains { name.contains($0) } }) { return .design }

        if !toolSet.isDisjoint(with: terminalTools) { return .terminal }
        if !toolSet.isDisjoint(with: planningTools) { return .planning }
        if !toolSet.isDisjoint(with: explorationTools) { return .exploration }

        // Default: anything else (Skill, AskUserQuestion, etc.)
        return .conversation
    }

    static let codingTools: Set<String> = ["Edit", "Write", "NotebookEdit"]
    static let designKeywords = ["figma", "design"]
    static let terminalTools: Set<String> = ["Bash"]
    static let planningTools: Set<String> = ["EnterPlanMode", "ExitPlanMode", "TaskCreate", "TaskUpdate", "TaskList", "TaskOutput", "Task", "TodoWrite"]
    static let explorationTools: Set<String> = ["Read", "Grep", "Glob", "Agent", "WebSearch", "WebFetch", "ToolSearch"]

    /// Categories in the order `classify` checks them: a turn takes the first one that matches.
    static let classificationOrder: [ActivityCategory] = [.coding, .design, .terminal, .planning, .exploration, .conversation]

    /// What puts a turn in this category, for the in-app explanation.
    var rule: String {
        func list(_ tools: Set<String>) -> String { tools.sorted().joined(separator: ", ") }
        switch self {
        case .coding: return "Edits files: \(list(Self.codingTools))."
        case .design: return "Uses a tool whose name contains \(Self.designKeywords.map { "\"\($0)\"" }.joined(separator: " or "))."
        case .terminal: return "Runs shell commands: \(list(Self.terminalTools))."
        case .planning: return "Plans or tracks tasks: \(list(Self.planningTools))."
        case .exploration: return "Reads, searches or delegates: \(list(Self.explorationTools))."
        case .conversation: return "No tools, or only tools not listed above."
        }
    }

    /// Short explanation of how activity is inferred, shown next to the activity section.
    static let explanation = "Each assistant turn is put in one category from the tools it called, checked in this order; the first match wins. It's an inference from tool calls, not a measure of time spent or of intent. Costs are API-equivalent estimates."
}

struct ActivityEntry: Identifiable {
    let category: ActivityCategory
    var cost: Double = 0
    var turns: Int = 0
    var tokens: Int = 0

    var id: String { category.id }
}

struct ActivityAggregator {
    private(set) var entries: [ActivityCategory: ActivityEntry] = [:]

    mutating func add(category: ActivityCategory, cost: Double, tokens: Int) {
        if var existing = entries[category] {
            existing.cost += cost
            existing.turns += 1
            existing.tokens += tokens
            entries[category] = existing
        } else {
            entries[category] = ActivityEntry(category: category, cost: cost, turns: 1, tokens: tokens)
        }
    }

    mutating func merge(_ other: ActivityAggregator) {
        for (category, entry) in other.entries {
            if var existing = entries[category] {
                existing.cost += entry.cost
                existing.turns += entry.turns
                existing.tokens += entry.tokens
                entries[category] = existing
            } else {
                entries[category] = entry
            }
        }
    }

    var sortedEntries: [ActivityEntry] {
        entries.values.sorted { $0.cost > $1.cost }
    }

    var totalCost: Double {
        entries.values.reduce(0) { $0 + $1.cost }
    }

    var totalTurns: Int {
        entries.values.reduce(0) { $0 + $1.turns }
    }
}
