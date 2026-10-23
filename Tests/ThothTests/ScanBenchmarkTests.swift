// Tests/ThothTests/ScanBenchmarkTests.swift
import Foundation
import Testing
@testable import Thoth

/// Opt-in benchmark over a large synthetic history in a temporary directory.
///
///     THOTH_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter ScanBenchmark
///
/// Scale knobs: THOTH_BENCH_PROJECTS, THOTH_BENCH_FILES (per project), THOTH_BENCH_MESSAGES (per file).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["THOTH_BENCH"] != nil))
struct ScanBenchmark {
    private static func env(_ key: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? fallback
    }

    private static func measure(_ label: String, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "BENCH %-28@ %9.1f ms", label as NSString, ms))
        return ms
    }

    private static func maxRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
    }

    @Test func largeHistory() throws {
        let projects = Self.env("THOTH_BENCH_PROJECTS", 30)
        let filesPerProject = Self.env("THOTH_BENCH_FILES", 20)
        let messages = Self.env("THOTH_BENCH_MESSAGES", 400)

        var history = try SyntheticHistory(models: [
            "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001", "claude-opus-4-7",
            "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1",
        ])
        defer { history.remove() }
        try history.generate(projects: projects, filesPerProject: filesPerProject, messagesPerFile: messages)
        try history.writeSession(forFileAt: 0)

        print(String(format: "BENCH dataset: %d files, %.0f MB, %d responses",
                     history.files.count, Double(history.bytesWritten) / 1_048_576, history.requests.count))
        print(String(format: "BENCH maxrss before scans: %.0f MB", Self.maxRSSMB()))

        let service = ClaudeDataService(claudeDir: history.root.path)
        service.loadSessions()

        _ = Self.measure("full scan (cold)") { service.unifiedFullScan() }
        print(String(format: "BENCH maxrss after cold scan: %.0f MB", Self.maxRSSMB()))
        _ = Self.measure("full scan (warm, no changes)") { service.unifiedFullScan() }
        _ = Self.measure("today summary (cold)") { service.computeTodaySummaries() }
        _ = Self.measure("today summary (warm)") { service.computeTodaySummaries() }
        _ = Self.measure("active-session poll (idle)") { service.pollActiveSessions() }

        try history.append(messages: 50, toFiles: 10)
        _ = Self.measure("active-session poll (append)") { service.pollActiveSessions() }
        _ = Self.measure("today summary (append)") { service.computeTodaySummaries() }
        _ = Self.measure("full scan (10 files grew)") { service.unifiedFullScan() }
    }
}
