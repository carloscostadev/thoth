// Sources/Thoth/Services/ClaudeDataService.swift
import Foundation
import SwiftUI

enum DateFilter: String, CaseIterable, Identifiable {
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case allTime = "All Time"

    var id: String { rawValue }

    var startDate: Date? {
        let cal = Calendar.current
        switch self {
        case .today: return cal.startOfDay(for: Date())
        case .last7Days: return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))
        case .last30Days: return cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date()))
        case .allTime: return nil
        }
    }
}

@Observable
final class ClaudeDataService {
    // Published state
    var activeSessions: [SessionData] = []
    var modelUsage = ModelUsageAggregator()
    var burnRateTracker = BurnRateTracker()
    /// Groups the history's transcripts count under (the project ranking's names) with their
    /// all-time cost whatever the filter, for the picker: highest cost first, temporary folders last.
    var availableProjects: [(name: String, cost: Double)] = []
    /// Project whose numbers are shown; nil = all projects. Set through `applyFilter`.
    private(set) var selectedGroup: String? = nil
    var dateFilter: DateFilter = .allTime
    var totalCost: Double = 0
    var totalTokens: Int = 0
    var todayCost: Double = 0
    var todayCalls: Int = 0
    var isConnected: Bool = false
    var todayActivity = ActivityAggregator()
    var weekCost: Double = 0
    var weekCalls: Int = 0
    var fifteenDaysCost: Double = 0
    var fifteenDaysCalls: Int = 0
    var monthCost: Double = 0
    var monthCalls: Int = 0
    var allTimeCost: Double = 0
    var allTimeCalls: Int = 0
    var todayTokens: Int = 0
    var weekTokens: Int = 0
    var fifteenDaysTokens: Int = 0
    var monthTokens: Int = 0
    var allTimeTokens: Int = 0

    /// Whether the figures come from a complete read, a partial one, or none yet.
    var dataStatus: DataStatus = .initial
    /// Last time a scan read the history (fully or partially).
    var lastSuccessfulRead: Date? = nil

    // Analytics
    var dailyCostSeries: [(date: Date, cost: Double, tokens: Int)] = [] // last 30 days, oldest first
    var projectedMonthCost: Double = 0
    var cacheHitRate: Double = 0 // 0..1
    var cacheSavings: Double = 0 // $ saved vs no-cache pricing
    var projectRanking: [(name: String, cost: Double)] = [] // all time, highest first
    var heatmap: [[Double]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    var heatmapMax: Double = 0

    // Internal state — all of the below are owned by analyticsQueue (bg-only).
    // The serial queue serialises access; never touch from main thread. They are excluded from
    // observation so background mutations never go through the SwiftUI observation registrar.
    @ObservationIgnored private var pollCursors: [String: UsageLogCursor] = [:] // JSONL file -> read position
    @ObservationIgnored private var bgActiveSessions: [SessionData] = []
    @ObservationIgnored private var bgSelectedGroup: String? = nil
    @ObservationIgnored private var bgDateFilter: DateFilter = .allTime
    @ObservationIgnored private var sessionDirs: [String: String] = [:] // sessionId -> projects/<dir>
    @ObservationIgnored private var todayFileCaches: [String: TodayFileCache] = [:]
    @ObservationIgnored private var todayCacheDay: Date? = nil
    /// Last time the today summary walked the whole projects tree; see `computeTodaySummaries`.
    @ObservationIgnored private var todayLastWalk: Date = .distantPast
    private static let todayWalkInterval: TimeInterval = 60
    @ObservationIgnored private var fullScanCaches: [String: FullFileCache] = [:]
    @ObservationIgnored private var heuristicGroups: [String: String] = [:] // projects/<dir> name -> group
    /// Session cwd -> ranking group, rebuilt whenever a new cwd shows up (see `ProjectGroup.Resolver`).
    @ObservationIgnored private var cwdGroups: [String: String] = [:]
    /// Background copy of `dataStatus`.
    @ObservationIgnored private var bgStatus: DataStatus = .initial
    /// Which transcript counts each response, shared by every scan; see `ResponseRegistry`.
    @ObservationIgnored private let responses = ResponseRegistry()

    private struct TodayFileCache {
        var mtime: Date = .distantPast
        var cursor = UsageLogCursor()
        var cost: Double = 0
        var tokens: Int = 0
        var calls: Int = 0
        var activity = ActivityAggregator()
        /// Latest assistant response. Its tool_use blocks may still be on lines not written yet,
        /// so it is classified only once the next response starts (or provisionally when summed).
        var pending: (tools: [String], cost: Double, tokens: Int)?
        /// Folder-name group, for a file the heavy scan hasn't read yet (see `groupKey(forFile:)`).
        var heuristicGroup = ""

        mutating func commitPending() {
            guard let p = pending else { return }
            activity.add(category: ActivityCategory.classify(tools: p.tools), cost: p.cost, tokens: p.tokens)
            pending = nil
        }

        var activityIncludingPending: ActivityAggregator {
            var copy = self
            copy.commitPending()
            return copy.activity
        }
    }

    /// Per-file aggregate for the heavy scan. Stores only time-independent counts
    /// (totals, per-day buckets, heat by weekday × hour). Period buckets (week/15d/month)
    /// are derived from `perDay` at aggregation time, so they update with the calendar
    /// without requiring re-parse. Group filtering is also aggregation-time: the group is resolved
    /// from the session's first `cwd` (or the folder-name heuristic) when aggregating, because a
    /// worktree's group depends on the other folders in the history.
    private struct FullFileCache {
        var mtime: Date = .distantPast
        var size: UInt64 = 0
        /// Inode and read position: a file that only grew is read from `cursor` on the next scan.
        var fileNumber: UInt64 = 0
        var cursor = UsageLogCursor()
        var cwd: String?
        var heuristicGroup: String = ""
        var modelTokens: [String: (input: Int, output: Int, cacheWrite: Int, cacheRead: Int, cost: Double)] = [:]
        var sessionModels: Set<String> = []
        var perDay: [Date: (cost: Double, tokens: Int, calls: Int)] = [:]
        var heat: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var totalCacheRead: Int = 0
        var totalInput: Int = 0
        var savings: Double = 0
        var totalCost: Double = 0
        var totalTokens: Int = 0
        var totalCalls: Int = 0
        /// Responses left out because another transcript counts them. If that transcript
        /// goes away, this one is read again so they are counted here.
        var duplicatesSkipped: Int = 0
    }

    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var sessionTimer: Timer?
    @ObservationIgnored private var analyticsTimer: Timer?
    private let analyticsQueue = DispatchQueue(label: "com.carloscosta.thoth.analytics", qos: .utility)

    private let claudeDir: String
    /// Day boundaries, windows and the heatmap follow this calendar's time zone (the system's
    /// unless a test pins one) and this clock.
    private let currentCalendar: () -> Calendar
    private let clock: () -> Date
    private var calendar: Calendar { currentCalendar() }
    /// Zone the per-day buckets in `fullScanCaches` were computed in.
    @ObservationIgnored private var fullScanTimeZone: TimeZone?

    /// Where the project filter is remembered between launches; nil keeps it in memory only.
    @ObservationIgnored private let defaults: UserDefaults?
    static let projectFilterKey = "projectFilter"

    init(claudeDir: String = NSHomeDirectory() + "/.claude",
         calendar: @escaping () -> Calendar = { .current },
         now: @escaping () -> Date = Date.init,
         defaults: UserDefaults? = .standard) {
        self.claudeDir = claudeDir
        self.currentCalendar = calendar
        self.clock = now
        self.defaults = defaults
        let saved = defaults?.string(forKey: Self.projectFilterKey)
        selectedGroup = saved
        bgSelectedGroup = saved
    }

    /// Main thread. Safe to call more than once (the menu bar label's onAppear can fire again);
    /// only the first call schedules work.
    func start() {
        guard pollTimer == nil else { return }

        // All file I/O runs on analyticsQueue (serial). The main thread is reserved for UI
        // and only receives final @Observable writes via DispatchQueue.main.async.
        analyticsQueue.async { [weak self] in
            guard let self else { return }
            self.loadSessions()
            self.unifiedFullScan()
        }

        // Incremental poll of active sessions + today summary.
        // Was 2s on main thread — the today scan re-read all of today's JSONLs every tick.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.analyticsQueue.async {
                self?.pollActiveSessions()
                self?.computeTodaySummaries()
            }
        }
        // Re-scan sessions every 30s (was 10s on main).
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.analyticsQueue.async {
                self?.loadSessions()
            }
        }
        // Full heavy scan every 5 minutes (was 60s). Polls keep "today" and active sessions live in between.
        analyticsTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.analyticsQueue.async {
                self?.unifiedFullScan()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        sessionTimer?.invalidate()
        analyticsTimer?.invalidate()
        pollTimer = nil
        sessionTimer = nil
        analyticsTimer = nil
    }

    /// Incremental heavy scan. Per-file aggregates are cached keyed by path; files whose
    /// (mtime, size) haven't changed are skipped without any I/O. The project filter is applied
    /// at aggregation time (`publishAggregates`), so switching projects reads no file.
    /// First-run still reads everything once; subsequent runs read only what was appended to
    /// files that grew, and re-read whole only files that were replaced or shrank.
    /// Runs on analyticsQueue.
    func unifiedFullScan() {
        let projectsDir = claudeDir + "/projects"
        guard let dirs = listProjectsDir(projectsDir) else { return }

        let cal = calendar
        let now = clock()

        // Per-file day buckets are frozen in the zone they were computed in; after a time zone
        // change, re-parse everything once so days and hours follow the new zone.
        if fullScanTimeZone != cal.timeZone {
            fullScanCaches.removeAll()
            fullScanTimeZone = cal.timeZone
        }

        // Pass 1: find files that changed since their cached aggregate.
        var seenFiles: Set<String> = []
        var jobs: [FullScanJob] = []
        // Folders or files the walk couldn't read, then transcripts that couldn't be opened.
        var failedItems = 0
        for dir in dirs {
            let heuristicGroupName = heuristicGroup(forDir: dir)
            let dirPath = projectsDir + "/" + dir
            for file in listJSONLs(in: dirPath, failures: &failedItems) {
                let filePath = file.path, mtime = file.mtime, size = file.size, fileNumber = file.fileNumber
                seenFiles.insert(filePath)

                let cached = fullScanCaches[filePath]
                if let cached, cached.mtime == mtime, cached.size == size {
                    continue
                }
                // Claude Code only appends to a transcript: the same file, not smaller, still with a
                // line break where the last scan stopped, carries on from there.
                let base = cached.flatMap {
                    $0.fileNumber == fileNumber && size >= $0.size && Self.endsLine(atPath: filePath, offset: $0.cursor.offset)
                        ? $0 : nil
                }
                jobs.append(FullScanJob(path: filePath, mtime: mtime, fileNumber: fileNumber,
                                        heuristicGroup: heuristicGroupName, base: base))
            }
        }

        // A transcript that disappeared, or is read again from the start, no longer counts the
        // responses it held: free them, and re-read the transcripts that left them out as copies.
        let gone = Set(fullScanCaches.keys).subtracting(seenFiles)
        let restarted = jobs.filter { $0.base == nil && fullScanCaches[$0.path] != nil }.map(\.path)
        if !gone.isEmpty || !restarted.isEmpty,
           responses.release(ownedBy: gone.union(restarted)) > 0 {
            let queued = Set(jobs.map(\.path))
            for (path, cache) in fullScanCaches where cache.duplicatesSkipped > 0 && !gone.contains(path) {
                if queued.contains(path) {
                    if let i = jobs.firstIndex(where: { $0.path == path }) { jobs[i].base = nil }
                } else {
                    jobs.append(FullScanJob(path: path, mtime: cache.mtime, fileNumber: cache.fileNumber,
                                            heuristicGroup: cache.heuristicGroup, base: nil))
                }
            }
            // Today's per-file sums were split by the old owners.
            todayFileCaches.removeAll()
            todayLastWalk = .distantPast
        }

        // Prune entries for files that disappeared.
        for key in gone {
            fullScanCaches.removeValue(forKey: key)
            pollCursors.removeValue(forKey: key)
        }

        // Transcripts that lost a response to a better copy (found by the today summary or the
        // poll since the last scan) are read again without it.
        requeue(responses.takeDispossessed(.fullScan), into: &jobs)

        // Re-parse them. The first read since launch reports its progress (a cold start can take
        // seconds).
        let progress: ScanProgress? = {
            guard case .loading = bgStatus, !jobs.isEmpty else { return nil }
            return ScanProgress(total: jobs.count) { [weak self] read, total in
                DispatchQueue.main.async {
                    guard let self, case .loading = self.dataStatus else { return }
                    self.dataStatus = .loading(filesRead: read, filesTotal: total)
                }
            }
        }()
        failedItems += runFullScanJobs(jobs, calendar: cal, progress: progress)
        // A transcript just read may have taken responses over from one read earlier, or from one
        // read at the same time on another thread: read those again, without them. A transcript
        // read from the start takes nothing over, so this settles in one round.
        for _ in 0..<8 {
            var again: [FullScanJob] = []
            requeue(responses.takeDispossessed(.fullScan), into: &again)
            if again.isEmpty { break }
            failedItems += runFullScanJobs(again, calendar: cal, progress: nil)
        }

        // Worktrees join the project they belong to; temporary folders and scratchpads are one group.
        let cwds = Set(fullScanCaches.values.compactMap(\.cwd))
        if cwds.count != cwdGroups.count || !cwds.allSatisfy({ cwdGroups[$0] != nil }) {
            let resolver = ProjectGroup.Resolver(cwds: cwds)
            cwdGroups = Dictionary(uniqueKeysWithValues: cwds.map { ($0, resolver.groupName(forCwd: $0)) })
        }

        let status = DataStatus.afterScan(totalFiles: seenFiles.count, failedItems: failedItems)
        bgStatus = status
        publishAggregates(scanStatus: status)
    }

    /// Runs on analyticsQueue. Queues a read from the start of each of `paths` the heavy scan
    /// knows, without releasing the responses they count (their content didn't change).
    private func requeue(_ paths: Set<String>, into jobs: inout [FullScanJob]) {
        for path in paths {
            if let i = jobs.firstIndex(where: { $0.path == path }) {
                jobs[i].base = nil
            } else if let cache = fullScanCaches[path] {
                jobs.append(FullScanJob(path: path, mtime: cache.mtime, fileNumber: cache.fileNumber,
                                        heuristicGroup: cache.heuristicGroup, base: nil))
            }
        }
    }

    /// Runs on analyticsQueue. Parses `jobs` into `fullScanCaches`; returns how many couldn't be
    /// read. Files are independent, so a cold start (every file) spreads over the available
    /// cores; results are merged back here.
    private func runFullScanJobs(_ jobs: [FullScanJob], calendar cal: Calendar, progress: ScanProgress?) -> Int {
        let responses = self.responses
        var results = [(cache: FullFileCache, cursor: UsageLogCursor)?](repeating: nil, count: jobs.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer // each iteration writes only its own index
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                autoreleasepool {
                    slots[i] = Self.buildFullFileCache(jobs[i], calendar: cal, responses: responses)
                }
                progress?.fileDone()
            }
        }
        var failed = 0
        for (job, result) in zip(jobs, results) {
            guard let result else {
                failed += 1
                continue
            }
            fullScanCaches[job.path] = result.cache
            pollCursors[job.path] = result.cursor
        }
        return failed
    }

    /// Runs on analyticsQueue. Pass 2 of the heavy scan, also run on its own when the project
    /// filter changes: sums the per-file caches, keeping only the selected project's files, and
    /// publishes the result (with `scanStatus`, when a scan just read the history). Reads no file.
    /// A selected project the history no longer has falls back to all projects, once a complete
    /// read confirms it is gone.
    private func publishAggregates(scanStatus: DataStatus?) {
        let cal = calendar
        let now = clock()

        var groupCosts: [String: Double] = [:]
        for cache in fullScanCaches.values {
            groupCosts[groupKey(of: cache), default: 0] += cache.totalCost
        }
        var groupFilter = bgSelectedGroup
        var dropped: String? = nil
        if let group = groupFilter, bgStatus == .ready, groupCosts[group] == nil {
            dropped = group
            groupFilter = nil
            bgSelectedGroup = nil
        }
        let projects = ProjectGroup.menuOrder(groupCosts)

        // Each window counts today as its first day, so "7 Days" is today plus the 6 days before
        // (same convention as the 30-day window and chart).
        let today = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let fifteenStart = cal.date(byAdding: .day, value: -14, to: today)!
        let windowStart = cal.date(byAdding: .day, value: -29, to: today)!
        let monthStart = windowStart
        let calendarMonthStart = cal.dateInterval(of: .month, for: today)?.start ?? today

        var aggregator = ModelUsageAggregator()
        var totalC = 0.0
        var totalT = 0
        var wCost = 0.0, wCalls = 0, wTokens = 0
        var fCost = 0.0, fCalls = 0, fTokens = 0
        var mCost = 0.0, mCalls = 0, mTokens = 0
        var aCost = 0.0, aCalls = 0, aTokens = 0
        var monthToDate = 0.0
        var dayCosts: [Date: Double] = [:]
        var dayTokens: [Date: Int] = [:]
        var totalCacheRead = 0
        var totalInput = 0
        var savings = 0.0
        var projectCosts: [String: Double] = [:]
        var heat = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)

        for (_, cache) in fullScanCaches {
            let groupKey = groupKey(of: cache)
            if let group = groupFilter, groupKey != group { continue }

            totalC += cache.totalCost
            totalT += cache.totalTokens
            aCost += cache.totalCost
            aCalls += cache.totalCalls
            aTokens += cache.totalTokens

            for (model, tokens) in cache.modelTokens {
                let usage = TokenUsage(
                    inputTokens: tokens.input,
                    outputTokens: tokens.output,
                    cacheWriteTokens: tokens.cacheWrite,
                    cacheReadTokens: tokens.cacheRead
                )
                aggregator.add(usage: usage, cost: tokens.cost, model: model)
            }
            for model in cache.sessionModels {
                aggregator.incrementSessionCount(for: model)
            }

            for (day, stats) in cache.perDay {
                if day >= monthStart { mCost += stats.cost; mCalls += stats.calls; mTokens += stats.tokens }
                if day >= fifteenStart { fCost += stats.cost; fCalls += stats.calls; fTokens += stats.tokens }
                if day >= weekStart { wCost += stats.cost; wCalls += stats.calls; wTokens += stats.tokens }
                if day >= calendarMonthStart { monthToDate += stats.cost }
                if day >= windowStart {
                    dayCosts[day, default: 0] += stats.cost
                    dayTokens[day, default: 0] += stats.tokens
                }
            }

            totalCacheRead += cache.totalCacheRead
            totalInput += cache.totalInput
            savings += cache.savings
            projectCosts[groupKey, default: 0] += cache.totalCost

            for weekday in 0..<7 {
                for hour in 0..<24 {
                    heat[weekday][hour] += cache.heat[weekday][hour]
                }
            }
        }

        var series: [(date: Date, cost: Double, tokens: Int)] = []
        for offset in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: offset, to: windowStart) else { continue }
            series.append((day, dayCosts[day] ?? 0, dayTokens[day] ?? 0))
        }

        let last7 = series.suffix(7).map { $0.cost }.reduce(0, +) / 7.0
        let monthRange = cal.range(of: .day, in: .month, for: now) ?? 1..<31
        let dayOfMonth = cal.component(.day, from: now)
        let remaining = max(0, monthRange.upperBound - dayOfMonth - 1)
        let projection = monthToDate + last7 * Double(remaining)

        let denom = Double(totalInput + totalCacheRead)
        let hitRate = denom > 0 ? Double(totalCacheRead) / denom : 0
        let ranking = projectCosts
            .map { (name: $0.key, cost: $0.value) }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.name < $1.name }
        let heatMax = heat.flatMap { $0 }.max() ?? 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let scanStatus {
                self.dataStatus = scanStatus
                self.lastSuccessfulRead = now
            }
            self.availableProjects = projects
            if let dropped, self.selectedGroup == dropped {
                self.selectedGroup = nil
                self.persistProjectFilter(nil)
            }
            // Another project picked meanwhile: its own aggregation is queued after this one.
            guard self.selectedGroup == groupFilter else { return }
            self.modelUsage = aggregator
            self.totalCost = totalC
            self.totalTokens = totalT

            self.weekCost = wCost; self.weekCalls = wCalls; self.weekTokens = wTokens
            self.fifteenDaysCost = fCost; self.fifteenDaysCalls = fCalls; self.fifteenDaysTokens = fTokens
            self.monthCost = mCost; self.monthCalls = mCalls; self.monthTokens = mTokens
            self.allTimeCost = aCost; self.allTimeCalls = aCalls; self.allTimeTokens = aTokens

            self.dailyCostSeries = series
            self.projectedMonthCost = projection
            self.cacheHitRate = hitRate
            self.cacheSavings = savings
            self.projectRanking = ranking
            self.heatmap = heat
            self.heatmapMax = heatMax
        }
        // Today's figures follow the fallback right away.
        if dropped != nil { publishTodaySums(readAt: nil) }
    }

    /// Runs on analyticsQueue. Lists the projects folder, or publishes why it can't be read
    /// (missing or unreadable) and returns nil.
    private func listProjectsDir(_ projectsDir: String) -> [String]? {
        let status: DataStatus
        switch DataStatus.probe(projectsDir) {
        case .listed(let dirs): return dirs
        case .missing: status = .noHistory
        case .unreadable(let reason): status = .inaccessible(reason: reason)
        }
        if bgStatus != status {
            bgStatus = status
            DispatchQueue.main.async { [weak self] in self?.dataStatus = status }
        }
        return nil
    }

    /// Counts finished files from concurrent workers and reports every ~2% of `total`.
    private final class ScanProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0
        private let total: Int
        private let step: Int
        private let report: (_ read: Int, _ total: Int) -> Void

        init(total: Int, report: @escaping (_ read: Int, _ total: Int) -> Void) {
            self.total = total
            self.step = max(1, total / 50)
            self.report = report
            report(0, total)
        }

        func fileDone() {
            lock.lock()
            done += 1
            let read = done
            lock.unlock()
            if read % step == 0 || read == total { report(read, total) }
        }
    }

    private struct FullScanJob {
        let path: String
        let mtime: Date
        let fileNumber: UInt64
        let heuristicGroup: String
        /// Aggregate of the file's start, read by an earlier scan.
        var base: FullFileCache?
    }

    /// Which transcript counts each response. Resumed and forked sessions copy responses of the
    /// session they came from into their own file (same message id and request id). Every scan
    /// (heavy, today, poll) asks here, so a copy is never counted twice and all of them agree on
    /// where it counts: in the transcript where the response appears first by timestamp, ties
    /// going to the path that sorts first. The answer depends only on the files, never on the
    /// order they are read in.
    ///
    /// When a better transcript turns up after another one already counted the response, it
    /// takes the response over and the other one is reported as dispossessed, to each consumer
    /// separately (`takeDispossessed`), so its per-file sums can be rebuilt without the response.
    /// Keys are `UsageRecord.responseKey`. Locked: the heavy scan claims from several threads.
    final class ResponseRegistry: @unchecked Sendable {
        enum Claim: Equatable {
            /// `path` counts the response: it was unclaimed, or `path` already counts it.
            case counts
            /// `path` counts it instead of the transcript that did; that one is dispossessed.
            case takesOver
            /// Another transcript counts it.
            case skips

            var counts: Bool { self != .skips }
        }

        /// Scans that keep per-file sums and must rebuild those of dispossessed transcripts.
        enum Consumer { case fullScan, today }

        private struct Owner {
            let path: String
            let timestamp: Date

            func yields(to path: String, at timestamp: Date) -> Bool {
                timestamp != self.timestamp ? timestamp < self.timestamp : path < self.path
            }
        }

        private let lock = NSLock()
        private var owners: [Int: Owner] = [:]
        private var dispossessed: [Consumer: Set<String>] = [:]

        func claim(_ key: Int?, for path: String, at timestamp: Date) -> Claim {
            guard let key else { return .counts }
            lock.lock()
            defer { lock.unlock() }
            guard let owner = owners[key] else {
                owners[key] = Owner(path: path, timestamp: timestamp)
                return .counts
            }
            if owner.path == path { return .counts }
            guard owner.yields(to: path, at: timestamp) else { return .skips }
            owners[key] = Owner(path: path, timestamp: timestamp)
            dispossessed[.fullScan, default: []].insert(owner.path)
            dispossessed[.today, default: []].insert(owner.path)
            return .takesOver
        }

        /// Frees the responses counted by `paths`. Returns how many were freed.
        func release(ownedBy paths: Set<String>) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let before = owners.count
            owners = owners.filter { !paths.contains($0.value.path) }
            return before - owners.count
        }

        /// Transcripts that lost a response they counted since `consumer` last asked.
        func takeDispossessed(_ consumer: Consumer) -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return dispossessed.removeValue(forKey: consumer) ?? []
        }
    }

    /// Parses a JSONL file into its time-independent aggregate, plus the read position the
    /// active-session poll should continue from: from the end of `job.base`, else from the start.
    /// Responses another transcript counts (`responses`) are left out. Depends only on
    /// the file, `job` and the registry: safe to run concurrently. Returns nil if the file can't
    /// be read.
    private static func buildFullFileCache(_ job: FullScanJob, calendar cal: Calendar,
                                           responses: ResponseRegistry) -> (cache: FullFileCache, cursor: UsageLogCursor)? {
        var cache = job.base ?? FullFileCache()
        cache.mtime = job.mtime
        cache.fileNumber = job.fileNumber
        var fileCwd = cache.cwd
        var cursor = cache.cursor
        let start = cursor.offset
        // Calendar lookups are the hot spot after JSON decoding; every zone offset is a multiple
        // of 15 minutes, so one lookup per quarter hour gives the same day / weekday / hour.
        var buckets: [Int: (day: Date, weekday: Int, hour: Int)] = [:]

        // The parser looks for a cwd again in every chunk it reads; the session's first one wins.
        let onCwd: ((String) -> Void)? = fileCwd == nil ? { if fileCwd == nil { fileCwd = $0 } } : nil
        let bytesRead = UsageLogParser.parseFile(atPath: job.path, cursor: &cursor, onCwd: onCwd) { record in
            guard record.isCounted else { return }
            // A correction follows its response: left out with it.
            guard responses.claim(record.responseKey, for: job.path, at: record.timestamp).counts else {
                if !record.isCorrection { cache.duplicatesSkipped += 1 }
                return
            }
            let d = record.timestamp
            let usage = record.usage
            let cost = record.cost
            let toks = usage.totalTokens
            // A correction completes a response already counted: tokens and cost, not a call.
            let calls = record.isCorrection ? 0 : 1

            cache.totalCost += cost
            cache.totalTokens += toks
            cache.totalCalls += calls
            cache.sessionModels.insert(record.model)

            if var existing = cache.modelTokens[record.model] {
                existing.input += usage.inputTokens
                existing.output += usage.outputTokens
                existing.cacheWrite += usage.cacheWriteTokens
                existing.cacheRead += usage.cacheReadTokens
                existing.cost += cost
                cache.modelTokens[record.model] = existing
            } else {
                cache.modelTokens[record.model] = (usage.inputTokens, usage.outputTokens,
                                                   usage.cacheWriteTokens, usage.cacheReadTokens, cost)
            }

            cache.totalCacheRead += usage.cacheReadTokens
            cache.totalInput += usage.inputTokens
            if let pricing = record.pricing {
                let rates = pricing.rates(forPromptTokens: usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens)
                cache.savings += Double(usage.cacheReadTokens) * (rates.input - rates.cacheRead) / 1_000_000.0
            }

            let bucketKey = Int((d.timeIntervalSince1970 / 900).rounded(.down))
            let bucket: (day: Date, weekday: Int, hour: Int)
            if let cached = buckets[bucketKey] {
                bucket = cached
            } else {
                bucket = (cal.startOfDay(for: d), (cal.component(.weekday, from: d) + 5) % 7, cal.component(.hour, from: d))
                buckets[bucketKey] = bucket
            }

            if var existing = cache.perDay[bucket.day] {
                existing.cost += cost
                existing.tokens += toks
                existing.calls += calls
                cache.perDay[bucket.day] = existing
            } else {
                cache.perDay[bucket.day] = (cost, toks, calls)
            }
            cache.heat[bucket.weekday][bucket.hour] += cost
        }
        guard let bytesRead else { return nil }

        // Size of what was actually read: if the file grew meanwhile, the next scan sees a
        // different size and reads the rest.
        cache.size = start + bytesRead
        cache.cursor = cursor
        cache.cwd = fileCwd
        cache.heuristicGroup = job.heuristicGroup
        return (cache, cursor)
    }

    /// True when the byte before `offset` is a line break (or `offset` is 0): the file still
    /// looks like the one whose first `offset` bytes were read.
    private static func endsLine(atPath path: String, offset: UInt64) -> Bool {
        guard offset > 0 else { return true }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset - 1)) != nil,
              let byte = try? handle.read(upToCount: 1) else { return false }
        return byte.first == 0x0A
    }

    // MARK: - Sessions

    /// Runs on analyticsQueue.
    func loadSessions() {
        let sessionsDir = claudeDir + "/sessions"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return }

        var sessions: [SessionData] = []
        for file in files where file.hasSuffix(".json") {
            let path = sessionsDir + "/" + file
            guard let data = FileManager.default.contents(atPath: path),
                  let session = try? JSONDecoder().decode(SessionData.self, from: data) else { continue }
            if session.isAlive {
                sessions.append(session)
            }
        }
        bgActiveSessions = sessions
        let connected = !sessions.isEmpty
        DispatchQueue.main.async { [weak self] in
            self?.activeSessions = sessions
            self?.isConnected = connected
        }
    }

    /// Claude Code names a project's transcript folder after its cwd with every character other
    /// than ASCII letters and digits (per UTF-16 unit) replaced by "-":
    /// "/a/My Project_v1.2" -> "-a-My-Project-v1-2".
    static func projectDirName(forCwd cwd: String) -> String {
        let dash = UInt16(UInt8(ascii: "-"))
        let units = cwd.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return unit
            default: return dash
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Runs on analyticsQueue. Resolves (and caches) the transcript folder of an active session:
    /// the encoded cwd when it exists, otherwise whichever project folder holds `<sessionId>.jsonl`.
    private func transcriptDir(for session: SessionData) -> String? {
        if let cached = sessionDirs[session.sessionId] { return cached }
        let projectsDir = claudeDir + "/projects"
        var resolved: String? = nil
        let encoded = projectsDir + "/" + Self.projectDirName(forCwd: session.cwd)
        if FileManager.default.fileExists(atPath: encoded) {
            resolved = encoded
        } else if let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) {
            resolved = dirs.lazy
                .map { projectsDir + "/" + $0 }
                .first { FileManager.default.fileExists(atPath: $0 + "/" + session.sessionId + ".jsonl") }
        }
        if let resolved { sessionDirs[session.sessionId] = resolved }
        return resolved
    }

    // MARK: - Project Groups

    /// Runs on analyticsQueue. Folder-name group of a projects/<dir> folder. decodePath may probe
    /// the filesystem for ambiguous names; the answer is stable per name, so it is cached.
    private func heuristicGroup(forDir dir: String) -> String {
        if let cached = heuristicGroups[dir] { return cached }
        let name = ProjectGroup.isTemporary(encodedDir: dir)
            ? ProjectGroup.temporaryFoldersName
            : ProjectGroup.groupName(from: ProjectGroup.decodePath(dir))
        heuristicGroups[dir] = name
        return name
    }

    /// Runs on analyticsQueue. Group a transcript counts under, the same in every scan and in the
    /// ranking: its session's first cwd resolved against the whole history (worktrees join their
    /// project, temporary folders are one group), else the folder-name heuristic.
    private func groupKey(of cache: FullFileCache) -> String {
        cache.cwd.flatMap { cwdGroups[$0] } ?? cache.heuristicGroup
    }

    /// Runs on analyticsQueue. `groupKey(of:)` of a transcript the heavy scan has read, else
    /// `fallback` (a file written since the last heavy scan).
    private func groupKey(forFile path: String, fallback: @autoclosure () -> String) -> String {
        fullScanCaches[path].map(groupKey(of:)) ?? fallback()
    }

    private func persistProjectFilter(_ group: String?) {
        if let group {
            defaults?.set(group, forKey: Self.projectFilterKey)
        } else {
            defaults?.removeObject(forKey: Self.projectFilterKey)
        }
    }

    // MARK: - JSONL Scanning

    /// Runs on analyticsQueue. Reads only bytes appended to active-session JSONLs since the last
    /// poll (or the last heavy scan, whichever ran more recently). Aggregates the delta and dispatches
    /// the @Observable writes to the main thread in one batch.
    func pollActiveSessions() {
        var deltaUsages: [(usage: TokenUsage, cost: Double, model: String)] = []
        let sampleAt = Date()
        let filterStart = bgDateFilter.startDate
        let groupFilter = bgSelectedGroup

        for session in bgActiveSessions {
            guard let dirPath = transcriptDir(for: session) else { continue }

            // `<sessionId>.jsonl` (main transcript) and `<sessionId>/subagents/*.jsonl` (Agent-tool
            // sub-runs); the rest of the project folder is not listed.
            let main = dirPath + "/" + session.sessionId + ".jsonl"
            let paths = (FileManager.default.fileExists(atPath: main) ? [main] : [])
                + listJSONLs(in: dirPath + "/" + session.sessionId).map(\.path)
            let dirName = (dirPath as NSString).lastPathComponent
            for filePath in paths {
                // Another project's session is still read (its responses are claimed here), but
                // adds nothing to the figures on screen.
                let shown = groupFilter.map { groupKey(forFile: filePath, fallback: heuristicGroup(forDir: dirName)) == $0 } ?? true
                var cursor = pollCursors[filePath] ?? UsageLogCursor()
                readAppendedLines(of: filePath, cursor: &cursor) { record in
                    guard record.isCounted else { return }
                    if let filterStart, record.timestamp < filterStart { return }
                    // A response taken over from another transcript is already in the totals,
                    // under that one; the next heavy scan moves it.
                    guard responses.claim(record.responseKey, for: filePath, at: record.timestamp) == .counts,
                          shown else { return }
                    deltaUsages.append((record.usage, record.cost, record.model))
                }
                pollCursors[filePath] = cursor
            }
        }

        guard !deltaUsages.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedGroup == groupFilter else { return }
            for (usage, cost, model) in deltaUsages {
                self.modelUsage.add(usage: usage, cost: cost, model: model)
                self.totalCost += cost
                self.totalTokens += usage.totalTokens
                self.burnRateTracker.addSample(tokens: usage.totalTokens, at: sampleAt)
            }
        }
    }

    /// Runs on analyticsQueue. Parses the complete lines appended to `path` after `cursor` and
    /// advances it. A line still being written is left for the next call.
    private func readAppendedLines(of path: String, cursor: inout UsageLogCursor,
                                   onContinuation: ((_ toolNames: [String]) -> Void)? = nil,
                                   onRecord: (UsageRecord) -> Void) {
        UsageLogParser.parseFile(atPath: path, cursor: &cursor,
                                 onContinuation: onContinuation, onRecord: onRecord)
    }

    /// A transcript found by a walk, with the attributes the scans compare.
    private struct TranscriptFile {
        let path: String
        let mtime: Date
        let size: UInt64
        /// Inode: tells a file that grew from one that was replaced.
        let fileNumber: UInt64
    }

    private static let listingKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .fileIdentifierKey]
    private static let listingKeySet = Set(listingKeys)

    /// Every `.jsonl` file under `dir`, descending into subdirectories: Claude Code stores
    /// sub-agent transcripts at `<dir>/<sessionId>/subagents/agent-*.jsonl`, so a one-level scan
    /// misses the majority of usage data on heavy users of the Agent tool. The attributes come
    /// with the directory listing (one bulk call per folder) instead of one stat per file, about
    /// four times cheaper on a long history.
    private func listJSONLs(in dir: String) -> [TranscriptFile] {
        var ignored = 0
        return listJSONLs(in: dir, failures: &ignored)
    }

    /// Same walk, adding to `failures` each folder or transcript it found but couldn't read.
    private func listJSONLs(in dir: String, failures: inout Int) -> [TranscriptFile] {
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        var walkErrors = 0
        defer { failures += walkErrors }
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Self.listingKeys,
                                                      errorHandler: { _, _ in walkErrors += 1; return true }) else { return [] }
        // Paths keep the form the caller passed (the enumerator reports the real path of a
        // symlinked parent, e.g. /var -> /private/var): they are cache keys shared with the
        // other scans.
        var roots = [base.path + "/"]
        if let real = realpath(dir, nil) {
            roots.append(String(cString: real) + "/")
            free(real)
        }
        let prefix = dir + "/"
        var result: [TranscriptFile] = []
        for case let url as URL in en where url.lastPathComponent.hasSuffix(".jsonl") {
            guard let values = try? url.resourceValues(forKeys: Self.listingKeySet),
                  let mtime = values.contentModificationDate,
                  let root = roots.first(where: { url.path.hasPrefix($0) }) else {
                walkErrors += 1
                continue
            }
            result.append(TranscriptFile(path: prefix + url.path.dropFirst(root.count), mtime: mtime,
                                         size: UInt64(values.fileSize ?? 0),
                                         fileNumber: values.fileIdentifier ?? 0))
        }
        return result
    }

    /// Runs on analyticsQueue. Incremental: per-file cache keyed by path stores (mtime, offset, aggregates).
    /// On each tick, we only re-read files whose mtime advanced, and only the bytes appended since the
    /// last read. This replaces the previous full-file rescan that was burning ~25 MB/s on the main
    /// thread.
    ///
    /// Walking and stat-ing every transcript (thousands of files on a long history) is most of a
    /// tick's cost, so the whole tree is walked at most once per `todayWalkInterval`; ticks in
    /// between only re-check the files already known to have been written today. A file first
    /// written after the last walk joins today's totals at the next walk, within a minute.
    func computeTodaySummaries() {
        let projectsDir = claudeDir + "/projects"
        let cal = calendar
        let now = clock()
        let todayStart = cal.startOfDay(for: now)

        // Day rolled over → discard caches and walk again.
        if todayCacheDay != todayStart {
            todayFileCaches.removeAll()
            todayCacheDay = todayStart
            todayLastWalk = .distantPast
        }
        // Transcripts that lost a response to a better copy since the last tick are summed again
        // from the start, without it.
        restartDispossessedTodayCaches()

        // Every project's files are summed (the filter applies in `publishTodaySums`), so
        // switching projects reads nothing again.
        // (path, mtime, size, folder group): from the walk's listing, or one stat per known file
        // in between.
        var candidates: [(path: String, mtime: Date, size: UInt64, group: String)] = []
        // A known file that can no longer be stat-ed: this tick doesn't count as a full read.
        var statFailed = false
        if now.timeIntervalSince(todayLastWalk) >= Self.todayWalkInterval {
            guard let dirs = listProjectsDir(projectsDir) else { return }
            // The history appeared (or became readable) since the last heavy scan: read it now
            // instead of waiting up to five minutes.
            switch bgStatus {
            case .noHistory, .inaccessible: unifiedFullScan()
            case .loading, .partial, .ready: break
            }
            for dir in dirs {
                let group = heuristicGroup(forDir: dir)
                candidates += listJSONLs(in: projectsDir + "/" + dir).map { ($0.path, $0.mtime, $0.size, group) }
            }
            todayLastWalk = now
        } else {
            for (path, cache) in todayFileCaches {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date else {
                    statFailed = true
                    continue
                }
                candidates.append((path, mtime, (attrs[.size] as? NSNumber)?.uint64Value ?? 0, cache.heuristicGroup))
            }
        }

        var seenFiles: Set<String> = []

        for candidate in candidates {
            // Not modified today → cannot contain today's entries.
            if candidate.mtime < todayStart { continue }

            seenFiles.insert(candidate.path)
            readTodayFile(candidate.path, mtime: candidate.mtime, size: candidate.size,
                          group: candidate.group, todayStart: todayStart)
        }

        // A file read this tick may have taken responses over from one read earlier: sum that
        // one again now, so this tick doesn't count them twice.
        for path in restartDispossessedTodayCaches() where seenFiles.contains(path) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                statFailed = true
                continue
            }
            readTodayFile(path, mtime: mtime, size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                          group: todayFileCaches[path]?.heuristicGroup ?? "", todayStart: todayStart)
        }

        // Drop entries for files that disappeared (deleted/moved).
        for key in Array(todayFileCaches.keys) where !seenFiles.contains(key) {
            todayFileCaches.removeValue(forKey: key)
        }

        // Only a read of history already known to be readable refreshes "Updated …".
        publishTodaySums(readAt: bgStatus.showsFigures && !statFailed ? now : nil)
    }

    /// Runs on analyticsQueue. Reads what was appended to `path` since its today cache last read
    /// it, adding today's responses (the whole file again when it shrank).
    private func readTodayFile(_ path: String, mtime: Date, size currentSize: UInt64, group: String, todayStart: Date) {
        var cache = todayFileCaches[path] ?? TodayFileCache(heuristicGroup: group)

        // mtime unchanged since last read → nothing new in this file.
        if cache.mtime == mtime { return }

        // File shrunk (rotated/truncated) → discard cache and start over.
        if currentSize < cache.cursor.offset {
            cache = TodayFileCache(heuristicGroup: group)
        }

        var cursor = cache.cursor
        autoreleasepool {
            readAppendedLines(of: path, cursor: &cursor, onContinuation: { tools in
                cache.pending?.tools.append(contentsOf: tools)
            }) { record in
                if record.isCorrection {
                    // More output for the response just read: it is still `pending` (or
                    // already summed, when it was not an assistant line).
                    guard record.isCounted, record.timestamp >= todayStart,
                          responses.claim(record.responseKey, for: path, at: record.timestamp).counts else { return }
                    cache.cost += record.cost
                    cache.tokens += record.usage.totalTokens
                    cache.pending?.cost += record.cost
                    cache.pending?.tokens += record.usage.totalTokens
                    return
                }
                cache.commitPending()
                guard record.isCounted else { return }
                // Skip entries from before today (file may straddle midnight on first scan).
                if record.timestamp < todayStart { return }
                // A copy of a response another transcript counts.
                guard responses.claim(record.responseKey, for: path, at: record.timestamp).counts else { return }

                let lineCost = record.cost
                let tokens = record.usage.totalTokens
                cache.cost += lineCost
                cache.tokens += tokens
                cache.calls += 1
                if record.isAssistant {
                    cache.pending = (record.toolNames, lineCost, tokens)
                }
            }
        }
        cache.cursor = cursor
        cache.mtime = mtime
        todayFileCaches[path] = cache
    }

    /// Runs on analyticsQueue. Empties the today caches of transcripts that lost a response to a
    /// better copy, so they are read again without it. Returns their paths.
    @discardableResult
    private func restartDispossessedTodayCaches() -> [String] {
        var restarted: [String] = []
        for path in responses.takeDispossessed(.today) {
            guard let cache = todayFileCaches[path] else { continue }
            todayFileCaches[path] = TodayFileCache(heuristicGroup: cache.heuristicGroup)
            restarted.append(path)
        }
        return restarted
    }

    /// Runs on analyticsQueue. Sums today's per-file caches, keeping only the selected project's
    /// files, and publishes the result. Reads no file.
    private func publishTodaySums(readAt: Date?) {
        let groupFilter = bgSelectedGroup
        var sumCost = 0.0
        var sumTokens = 0
        var sumCalls = 0
        var sumActivity = ActivityAggregator()
        for (path, c) in todayFileCaches {
            if let group = groupFilter, groupKey(forFile: path, fallback: c.heuristicGroup) != group { continue }
            sumCost += c.cost
            sumTokens += c.tokens
            sumCalls += c.calls
            sumActivity.merge(c.activityIncludingPending)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let readAt { self.lastSuccessfulRead = readAt }
            // Another project picked meanwhile: its own sums are queued after these.
            guard self.selectedGroup == groupFilter else { return }
            self.todayCost = sumCost
            self.todayTokens = sumTokens
            self.todayCalls = sumCalls
            self.todayActivity = sumActivity
        }
    }

    /// Main thread. Shows only `group`'s numbers (nil: every project) and remembers the choice
    /// for the next launch. The per-file sums are added up again for the new project; no
    /// transcript is read again.
    func applyFilter(_ group: String?) {
        guard group != selectedGroup else { return }
        selectedGroup = group
        persistProjectFilter(group)
        // The burn rate only counts samples of the project shown.
        burnRateTracker = BurnRateTracker()
        analyticsQueue.async { [weak self] in
            guard let self else { return }
            self.bgSelectedGroup = group
            // Before the first read there is nothing to add up; that read uses the new filter.
            guard self.bgStatus.showsFigures else { return }
            self.publishAggregates(scanStatus: nil)
            self.publishTodaySums(readAt: nil)
        }
    }

    /// Blocks until the work already queued on the background queue has run. For tests.
    func waitForBackgroundWork() {
        analyticsQueue.sync {}
    }

    func applyDateFilter(_ filter: DateFilter) {
        dateFilter = filter
        burnRateTracker = BurnRateTracker()
        analyticsQueue.async { [weak self] in
            self?.bgDateFilter = filter
            self?.unifiedFullScan()
        }
    }

    // MARK: - Formatting Helpers

    var activityState: ActivityState {
        ActivityState.from(burnRate: burnRateTracker.currentRate, hasActiveSessions: isConnected)
    }

    var formattedBurnRate: String {
        let rate = burnRateTracker.currentRate
        if rate >= 1000 {
            return String(format: "%.1fk t/s", rate / 1000)
        }
        return String(format: "%.0f t/s", rate)
    }

    var formattedTotalTokens: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.2fM", Double(totalTokens) / 1_000_000)
        } else if totalTokens >= 1_000 {
            return String(format: "%.1fk", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }

    var formattedCost: String {
        String(format: "$%.2f", totalCost)
    }

    var formattedTodayCost: String {
        String(format: "$%.2f", todayCost)
    }

    var formattedWeekCost: String {
        String(format: "$%.2f", weekCost)
    }

    var formattedFifteenDaysCost: String {
        String(format: "$%.2f", fifteenDaysCost)
    }

    var formattedMonthCost: String {
        String(format: "$%.2f", monthCost)
    }

    var formattedAllTimeCost: String {
        String(format: "$%.2f", allTimeCost)
    }

    static func formatCalls(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.2fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
