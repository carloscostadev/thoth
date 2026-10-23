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
    var projectGroups: [ProjectGroup] = []
    var selectedGroup: String? = nil // nil = All Projects
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

    init(claudeDir: String = NSHomeDirectory() + "/.claude",
         calendar: @escaping () -> Calendar = { .current },
         now: @escaping () -> Date = Date.init) {
        self.claudeDir = claudeDir
        self.currentCalendar = calendar
        self.clock = now
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
            self.loadProjectGroups()
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
    /// (mtime, size) haven't changed are skipped without any I/O. The selectedGroup filter
    /// is applied at aggregation time, so switching groups no longer invalidates caches.
    /// First-run still reads everything once; subsequent runs read only what was appended to
    /// files that grew, and re-read whole only files that were replaced or shrank.
    /// Runs on analyticsQueue.
    func unifiedFullScan() {
        let projectsDir = claudeDir + "/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return }

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
        for dir in dirs {
            // decodePath may probe the filesystem for ambiguous names; the answer is stable per name.
            let heuristicGroupName: String
            if let cached = heuristicGroups[dir] {
                heuristicGroupName = cached
            } else {
                heuristicGroupName = ProjectGroup.groupName(from: ProjectGroup.decodePath(dir))
                heuristicGroups[dir] = heuristicGroupName
            }

            let dirPath = projectsDir + "/" + dir
            for filePath in enumerateJSONLs(in: dirPath) {
                seenFiles.insert(filePath)

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let size: UInt64 = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let fileNumber: UInt64 = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

                let cached = fullScanCaches[filePath]
                if let cached, cached.mtime == mtime, cached.size == size {
                    continue
                }
                // Claude Code only appends to a transcript: the same file, not smaller, carries on
                // from where the last scan stopped.
                let base = cached.flatMap { $0.fileNumber == fileNumber && size >= $0.size ? $0 : nil }
                jobs.append(FullScanJob(path: filePath, mtime: mtime, fileNumber: fileNumber,
                                        heuristicGroup: heuristicGroupName, base: base))
            }
        }

        // Re-parse them. Files are independent, so a cold start (every file) spreads over the
        // available cores; results are merged back here, on analyticsQueue.
        let pending = jobs
        var results = [(cache: FullFileCache, cursor: UsageLogCursor)?](repeating: nil, count: pending.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let slots = buffer // each iteration writes only its own index
            DispatchQueue.concurrentPerform(iterations: pending.count) { i in
                autoreleasepool {
                    slots[i] = Self.buildFullFileCache(pending[i], calendar: cal)
                }
            }
        }
        for (job, result) in zip(pending, results) {
            guard let result else { continue }
            fullScanCaches[job.path] = result.cache
            pollCursors[job.path] = result.cursor
        }

        // Prune entries for files that disappeared.
        for key in Array(fullScanCaches.keys) where !seenFiles.contains(key) {
            fullScanCaches.removeValue(forKey: key)
            pollCursors.removeValue(forKey: key)
        }

        // Worktrees and scratch folders join the project they belong to.
        let cwds = Set(fullScanCaches.values.compactMap(\.cwd))
        if cwds.count != cwdGroups.count || !cwds.allSatisfy({ cwdGroups[$0] != nil }) {
            let resolver = ProjectGroup.Resolver(cwds: cwds)
            cwdGroups = Dictionary(uniqueKeysWithValues: cwds.map { ($0, resolver.groupName(forCwd: $0)) })
        }

        // Pass 2: aggregate from caches. Filter by selectedGroup at this stage.
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

        let groupFilter = bgSelectedGroup

        for (_, cache) in fullScanCaches {
            let groupKey = cache.cwd.flatMap { cwdGroups[$0] } ?? cache.heuristicGroup
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
    }

    private struct FullScanJob {
        let path: String
        let mtime: Date
        let fileNumber: UInt64
        let heuristicGroup: String
        /// Aggregate of the file's start, read by an earlier scan.
        let base: FullFileCache?
    }

    /// Parses a JSONL file into its time-independent aggregate, plus the read position the
    /// active-session poll should continue from: from the end of `job.base` when the file still
    /// has a line break there, else from the start. Pure function of the file and `job`: safe to
    /// run concurrently. Returns nil if the file can't be read.
    private static func buildFullFileCache(_ job: FullScanJob,
                                           calendar cal: Calendar) -> (cache: FullFileCache, cursor: UsageLogCursor)? {
        var cache = FullFileCache()
        if let base = job.base, endsLine(atPath: job.path, offset: base.cursor.offset) {
            cache = base
        }
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
            guard let d = record.timestamp, let pricing = record.pricing else { return }
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
            let rates = pricing.rates(forPromptTokens: usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens)
            cache.savings += Double(usage.cacheReadTokens) * (rates.input - rates.cacheRead) / 1_000_000.0

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

    /// Runs on analyticsQueue.
    private func loadProjectGroups() {
        let projectsDir = claudeDir + "/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return }
        let groups = ProjectGroup.groupDirectories(dirs)
        DispatchQueue.main.async { [weak self] in
            self?.projectGroups = groups
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

        for session in bgActiveSessions {
            guard let dirPath = transcriptDir(for: session) else { continue }

            // Match both `<sessionId>.jsonl` (main transcript) and `<sessionId>/subagents/*.jsonl`
            // (Agent-tool sub-runs) — both contain the session id somewhere in the path.
            for filePath in enumerateJSONLs(in: dirPath) where filePath.contains(session.sessionId) {
                var cursor = pollCursors[filePath] ?? UsageLogCursor()
                readAppendedLines(of: filePath, cursor: &cursor) { record in
                    guard record.pricing != nil else { return }
                    if let filterStart, let date = record.timestamp, date < filterStart { return }
                    deltaUsages.append((record.usage, record.cost, record.model))
                }
                pollCursors[filePath] = cursor
            }
        }

        guard !deltaUsages.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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

    /// Returns absolute paths of every `.jsonl` file under `dir`, descending into subdirectories.
    /// Claude Code stores sub-agent transcripts at `<dir>/<sessionId>/subagents/agent-*.jsonl`,
    /// so a one-level scan misses the majority of usage data on heavy users of the Agent tool.
    private func enumerateJSONLs(in dir: String) -> [String] {
        guard let en = FileManager.default.enumerator(atPath: dir) else { return [] }
        var result: [String] = []
        while let item = en.nextObject() as? String {
            if item.hasSuffix(".jsonl") {
                result.append(dir + "/" + item)
            }
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

        // Day rolled over (or the group filter changed) → discard caches and walk again.
        if todayCacheDay != todayStart {
            todayFileCaches.removeAll()
            todayCacheDay = todayStart
            todayLastWalk = .distantPast
        }

        var candidates: [String] = []
        if now.timeIntervalSince(todayLastWalk) >= Self.todayWalkInterval {
            guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return }
            let groupFilter = bgSelectedGroup
            for dir in dirs {
                if let group = groupFilter {
                    let decoded = ProjectGroup.decodePath(dir)
                    let dirGroup = ProjectGroup.groupName(from: decoded)
                    if dirGroup != group { continue }
                }
                candidates += enumerateJSONLs(in: projectsDir + "/" + dir)
            }
            todayLastWalk = now
        } else {
            candidates = Array(todayFileCaches.keys)
        }

        var seenFiles: Set<String> = []

        for filePath in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let mtime = attrs[.modificationDate] as? Date else { continue }

            // Not modified today → cannot contain today's entries.
            if mtime < todayStart { continue }

            seenFiles.insert(filePath)
            var cache = todayFileCaches[filePath] ?? TodayFileCache()

            // mtime unchanged since last read → nothing new in this file.
            if cache.mtime == mtime { continue }

            // File shrunk (rotated/truncated) → discard cache and start over.
            let currentSize: UInt64 = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if currentSize < cache.cursor.offset {
                cache = TodayFileCache()
            }

            var cursor = cache.cursor
            autoreleasepool {
                readAppendedLines(of: filePath, cursor: &cursor, onContinuation: { tools in
                    cache.pending?.tools.append(contentsOf: tools)
                }) { record in
                    if record.isCorrection {
                        // More output for the response just read: it is still `pending` (or
                        // already summed, when it was not an assistant line).
                        guard record.pricing != nil else { return }
                        if let date = record.timestamp, date < todayStart { return }
                        cache.cost += record.cost
                        cache.tokens += record.usage.totalTokens
                        cache.pending?.cost += record.cost
                        cache.pending?.tokens += record.usage.totalTokens
                        return
                    }
                    cache.commitPending()
                    guard record.pricing != nil else { return }
                    // Skip entries from before today (file may straddle midnight on first scan).
                    if let date = record.timestamp, date < todayStart { return }

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
            todayFileCaches[filePath] = cache
        }

        // Drop entries for files that disappeared (deleted/moved/group-filtered out).
        for key in Array(todayFileCaches.keys) where !seenFiles.contains(key) {
            todayFileCaches.removeValue(forKey: key)
        }

        var sumCost = 0.0
        var sumTokens = 0
        var sumCalls = 0
        var sumActivity = ActivityAggregator()
        for (_, c) in todayFileCaches {
            sumCost += c.cost
            sumTokens += c.tokens
            sumCalls += c.calls
            sumActivity.merge(c.activityIncludingPending)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.todayCost = sumCost
            self.todayTokens = sumTokens
            self.todayCalls = sumCalls
            self.todayActivity = sumActivity
        }
    }

    func applyFilter(_ group: String?) {
        selectedGroup = group
        burnRateTracker = BurnRateTracker()
        analyticsQueue.async { [weak self] in
            guard let self else { return }
            self.bgSelectedGroup = group
            // Heavy-scan caches are aggregation-time filterable, so they survive group changes.
            // Today's caches filter at directory level — drop them so the next tick rebuilds for the new group.
            self.todayFileCaches.removeAll()
            self.todayCacheDay = nil
            self.unifiedFullScan()
        }
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
