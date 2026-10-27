// Tests/ThothTests/ActivityCategoryTests.swift
import Testing
@testable import Thoth

@Test func explanationCoversEveryCategoryInClassificationOrder() {
    #expect(Set(ActivityCategory.classificationOrder) == Set(ActivityCategory.allCases))
    #expect(ActivityCategory.classificationOrder.count == ActivityCategory.allCases.count)
    #expect(ActivityCategory.classificationOrder.last == .conversation)
    #expect(ActivityCategory.explanation.contains("not a measure of time"))
}

@Test func rulesNameTheToolsTheClassifierUses() {
    for tool in ActivityCategory.codingTools { #expect(ActivityCategory.coding.rule.contains(tool)) }
    for tool in ActivityCategory.terminalTools { #expect(ActivityCategory.terminal.rule.contains(tool)) }
    for tool in ActivityCategory.planningTools { #expect(ActivityCategory.planning.rule.contains(tool)) }
    for tool in ActivityCategory.explorationTools { #expect(ActivityCategory.exploration.rule.contains(tool)) }
    for keyword in ActivityCategory.designKeywords { #expect(ActivityCategory.design.rule.contains(keyword)) }
}

@Test func classificationFollowsTheExplainedOrder() {
    #expect(ActivityCategory.classify(tools: []) == .conversation)
    #expect(ActivityCategory.classify(tools: ["Read", "Edit", "Bash"]) == .coding)
    #expect(ActivityCategory.classify(tools: ["mcp__figma__get_code", "Bash"]) == .design)
    #expect(ActivityCategory.classify(tools: ["Bash", "TodoWrite"]) == .terminal)
    #expect(ActivityCategory.classify(tools: ["TodoWrite", "Read"]) == .planning)
    #expect(ActivityCategory.classify(tools: ["Grep"]) == .exploration)
    #expect(ActivityCategory.classify(tools: ["Skill"]) == .conversation)
}
