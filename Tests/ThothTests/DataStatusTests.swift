// Tests/ThothTests/DataStatusTests.swift
import Foundation
import Testing
@testable import Thoth

// MARK: - Pure state logic

@Test func scanOutcomeIsReadyOnlyWhenNothingFailed() {
    #expect(DataStatus.afterScan(totalFiles: 12, failedItems: 0) == .ready)
    #expect(DataStatus.afterScan(totalFiles: 0, failedItems: 0) == .ready)
    #expect(DataStatus.afterScan(totalFiles: 12, failedItems: 3) == .partial(failedItems: 3, totalFiles: 12))
}

@Test func aRealZeroNeverLooksLikeAFailedRead() {
    let zero = "$0.00"
    // A complete read of an empty history shows its zero.
    #expect(DataStatus.ready.display(zero) == zero)
    #expect(DataStatus.ready.notice == nil)
    // Every state without a read shows a placeholder and says why.
    let withoutRead: [DataStatus] = [.initial, .loading(filesRead: 3, filesTotal: 10), .noHistory,
                                     .inaccessible(reason: "permission denied")]
    for status in withoutRead {
        #expect(!status.showsFigures, "\(status)")
        #expect(status.display(zero) == DataStatus.placeholder, "\(status)")
        #expect(status.display(zero) != DataStatus.ready.display(zero), "\(status)")
        #expect(status.notice != nil, "\(status)")
    }
    // A partial read shows its figures, flagged.
    let partial = DataStatus.partial(failedItems: 2, totalFiles: 9)
    #expect(partial.display(zero) == zero)
    #expect(partial.notice == "2 transcripts couldn't be read and are left out")
    #expect(DataStatus.partial(failedItems: 1, totalFiles: 9).notice == "1 transcript couldn't be read and is left out")
}

@Test func listsAreHiddenUntilAReadSucceeds() {
    // No read yet, no history, unreadable history: the tabs' lists (periods, models, trends,
    // projects) give way to a "—" card with an explanation, so no $0.00 is ever shown.
    let withoutRead: [DataStatus] = [.initial, .loading(filesRead: 3, filesTotal: 10), .noHistory,
                                     .inaccessible(reason: "permission denied"), .inaccessible(reason: "read error")]
    for status in withoutRead {
        #expect(status.unavailableMessage != nil, "\(status)")
        #expect(status.display("$0.00") == "—", "\(status)")
        #expect(status.display("0 tok · 0 calls") == "—", "\(status)")
    }
    let messages = [DataStatus.initial, .noHistory, .inaccessible(reason: "x")].compactMap(\.unavailableMessage)
    #expect(Set(messages).count == 3)

    // A partial read keeps its figures (real but incomplete) and its notice.
    let partial = DataStatus.partial(failedItems: 2, totalFiles: 9)
    #expect(partial.unavailableMessage == nil)
    #expect(partial.display("$0.00") == "$0.00")
    #expect(partial.notice != nil)

    // A complete read shows its figures, zeros included, with no notice.
    #expect(DataStatus.ready.unavailableMessage == nil)
    #expect(DataStatus.ready.display("$0.00") == "$0.00")
    #expect(DataStatus.ready.notice == nil)
}

@Test func statesHaveDistinctNotices() {
    let notices = [DataStatus.initial, .loading(filesRead: 4, filesTotal: 10), .noHistory,
                   .inaccessible(reason: "permission denied"), .partial(failedItems: 1, totalFiles: 3)]
        .map { $0.notice ?? "" }
    #expect(Set(notices).count == notices.count)
    #expect(DataStatus.loading(filesRead: 4, filesTotal: 10).notice == "Reading history… 4 of 10 files")
    #expect(DataStatus.initial.notice == "Reading history…")
}

@Test func updatedText() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(DataStatus.updatedText(lastRead: nil, now: now) == "Not read yet")
    #expect(DataStatus.updatedText(lastRead: now, now: now) == "Updated just now")
    #expect(DataStatus.updatedText(lastRead: now.addingTimeInterval(-59), now: now) == "Updated just now")
    #expect(DataStatus.updatedText(lastRead: now.addingTimeInterval(-120), now: now) == "Updated 2 min ago")
    #expect(DataStatus.updatedText(lastRead: now.addingTimeInterval(-7_200), now: now) == "Updated 2 h ago")
    #expect(DataStatus.updatedText(lastRead: now.addingTimeInterval(-3 * 86_400), now: now) == "Updated 3 d ago")
    // A clock that went backwards doesn't produce a negative age.
    #expect(DataStatus.updatedText(lastRead: now.addingTimeInterval(30), now: now) == "Updated just now")
}

// MARK: - Folder probe and scans on synthetic trees

@MainActor
@Suite(.serialized)
struct DataStatusScanTests {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func startsLoadingWithoutAReadTime() {
        let service = ClaudeDataService(claudeDir: "/nonexistent")
        #expect(service.dataStatus == .initial)
        #expect(service.lastSuccessfulRead == nil)
    }

    @Test func missingHistoryIsNoHistory() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DataStatus.probe(root.appendingPathComponent("projects").path) == .missing)

        let service = ClaudeDataService(claudeDir: root.path)
        service.unifiedFullScan()
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.dataStatus == .noHistory)
        #expect(service.lastSuccessfulRead == nil)
    }

    @Test func emptyHistoryIsARealZero() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)

        let service = ClaudeDataService(claudeDir: root.path, now: { Self.fixedNow })
        service.unifiedFullScan()
        await drainMainQueue()
        #expect(service.dataStatus == .ready)
        #expect(service.allTimeCost == 0)
        #expect(service.lastSuccessfulRead == Self.fixedNow)
    }

    @Test func unreadableProjectsFolderIsInaccessible() async throws {
        let root = try tempDir()
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projects.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects.path)
            try? FileManager.default.removeItem(at: root)
        }
        // Running as root (some CI) bypasses permissions; nothing to check then.
        guard getuid() != 0 else { return }

        #expect(DataStatus.probe(projects.path) == .unreadable(reason: "permission denied"))
        let service = ClaudeDataService(claudeDir: root.path)
        service.unifiedFullScan()
        await drainMainQueue()
        #expect(service.dataStatus == .inaccessible(reason: "permission denied"))
        #expect(service.lastSuccessfulRead == nil)
        #expect(!service.dataStatus.showsFigures)
    }

    @Test func projectsPathThatIsAFileIsInaccessible() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        FileManager.default.createFile(atPath: projects.path, contents: Data())
        #expect(DataStatus.probe(projects.path) == .unreadable(reason: "not a folder"))
    }

    @Test func unreadableTranscriptsMakeAPartialRead() async throws {
        var history = try SyntheticHistory(models: ["claude-sonnet-5-5"], seed: 3)
        defer { history.remove() }
        try history.generate(projects: 2, filesPerProject: 2, messagesPerFile: 5)
        let locked = history.files[0].url.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
        guard getuid() != 0 else { return }

        let service = ClaudeDataService(claudeDir: history.root.path, now: { Self.fixedNow })
        service.unifiedFullScan()
        await drainMainQueue()
        #expect(service.dataStatus == .partial(failedItems: 1, totalFiles: 4))
        #expect(service.dataStatus.showsFigures)
        #expect(service.allTimeCalls == 15) // the three readable files
        #expect(service.lastSuccessfulRead == Self.fixedNow)

        // Readable again: the next scan is complete.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked)
        service.unifiedFullScan()
        await drainMainQueue()
        #expect(service.dataStatus == .ready)
        #expect(service.allTimeCalls == 20)
    }

    @Test func historyAppearingLaterIsPickedUpByTheTodayWalk() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ClaudeDataService(claudeDir: root.path)
        service.unifiedFullScan()
        await drainMainQueue()
        #expect(service.dataStatus == .noHistory)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: true)
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.dataStatus == .ready)
        #expect(service.lastSuccessfulRead != nil)
    }

    @Test func todaySummaryRefreshesTheReadTimeOnlyAfterAReadableScan() async throws {
        var history = try SyntheticHistory(models: ["claude-sonnet-5-5"], seed: 5)
        defer { history.remove() }
        try history.generate(projects: 1, filesPerProject: 1, messagesPerFile: 3, todayShare: 1)

        var now = Date()
        let service = ClaudeDataService(claudeDir: history.root.path, now: { now })
        // Before the first heavy scan, the today summary alone doesn't count as a read.
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.lastSuccessfulRead == nil)

        service.unifiedFullScan()
        await drainMainQueue()
        #expect(service.lastSuccessfulRead == now)

        now = now.addingTimeInterval(5)
        service.computeTodaySummaries()
        await drainMainQueue()
        #expect(service.lastSuccessfulRead == now)
    }
}
