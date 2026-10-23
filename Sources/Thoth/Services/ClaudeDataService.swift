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
    // The serial queue serialises access; never touch from main thread.
    private var fileOffsets: [String: UInt64] = [:] // JSONL file -> last read position
    private var bgActiveSessions: [SessionData] = []
    private var todayFileCaches: [String: TodayFileCache] = [:]
    private var todayCacheDay: Date? = nil
    private var fullScanCaches: [String: FullFileCache] = [:]

    private struct TodayFileCache {
        var mtime: Date = .distantPast
        var offset: UInt64 = 0
        var cost: Double = 0
        var tokens: Int = 0
        var calls: Int = 0
        var activity = ActivityAggregator()
    }

    /// Per-file aggregate for the heavy scan. Stores only time-independent counts
    /// (totals, per-day buckets, heat by weekday × hour). Period buckets (week/15d/month)
    /// are derived from `perDay` at aggregation time, so they update with the calendar
    /// without requiring re-parse. Group filtering is also aggregation-time — `groupKey`
    /// is resolved from the file's `cwd` (or path heuristic) and frozen in the cache.
    private struct FullFileCache {
        var mtime: Date = .distantPast
        var size: UInt64 = 0
        var groupKey: String = ""
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

    private var pollTimer: Timer?
    private var sessionTimer: Timer?
    private var analyticsTimer: Timer?
    private let analyticsQueue = DispatchQueue(label: "com.carloscosta.thoth.analytics", qos: .utility)

    private let claudeDir: String

    init(claudeDir: String = NSHomeDirectory() + "/.claude") {
        self.claudeDir = claudeDir
    }

    func start() {
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
    }

    /// Incremental heavy scan. Per-file aggregates are cached keyed by path; files whose
    /// (mtime, size) haven't changed are skipped without any I/O. The selectedGroup filter
    /// is applied at aggregation time, so switching groups no longer invalidates caches.
    /// First-run still reads everything once; subsequent runs only touch files that grew
    /// or rotated.
    func unifiedFullScan() {
        let projectsDir = claudeDir + "/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return }

        let cal = Calendar.current

        // Pass 1: refresh per-file caches by re-parsing only files that changed.
        var seenFiles: Set<String> = []
        for dir in dirs {
            let decoded = ProjectGroup.decodePath(dir)
            let heuristicGroupName = ProjectGroup.groupName(from: decoded)

            let dirPath = projectsDir + "/" + dir
            for filePath in enumerateJSONLs(in: dirPath) {
                seenFiles.insert(filePath)

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let size: UInt64 = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                if let cached = fullScanCaches[filePath], cached.mtime == mtime, cached.size == size {
                    continue
                }

                refreshFullScanCache(filePath: filePath, mtime: mtime, size: size,
                                     heuristicGroup: heuristicGroupName, calendar: cal)
            }
        }

        // Prune entries for files that disappeared.
        for key in Array(fullScanCaches.keys) where !seenFiles.contains(key) {
            fullScanCaches.removeValue(forKey: key)
            fileOffsets.removeValue(forKey: key)
        }

        // Pass 2: aggregate from caches. Filter by selectedGroup at this stage.
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.date(byAdding: .day, value: -7, to: today)!
        let fifteenStart = cal.date(byAdding: .day, value: -15, to: today)!
        let windowStart = cal.date(byAdding: .day, value: -29, to: today)!
        let monthStart = windowStart

        var aggregator = ModelUsageAggregator()
        var totalC = 0.0
        var totalT = 0
        var wCost = 0.0, wCalls = 0, wTokens = 0
        var fCost = 0.0, fCalls = 0, fTokens = 0
        var mCost = 0.0, mCalls = 0, mTokens = 0
        var aCost = 0.0, aCalls = 0, aTokens = 0
        var dayCosts: [Date: Double] = [:]
        var dayTokens: [Date: Int] = [:]
        var totalCacheRead = 0
        var totalInput = 0
        var savings = 0.0
        var projectCosts: [String: Double] = [:]
        var heat = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)

        let groupFilter = selectedGroup

        for (_, cache) in fullScanCaches {
            if let group = groupFilter, cache.groupKey != group { continue }

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
                if day >= windowStart {
                    dayCosts[day, default: 0] += stats.cost
                    dayTokens[day, default: 0] += stats.tokens
                }
            }

            totalCacheRead += cache.totalCacheRead
            totalInput += cache.totalInput
            savings += cache.savings
            projectCosts[cache.groupKey, default: 0] += cache.totalCost

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
        let monthRange = cal.range(of: .day, in: .month, for: Date()) ?? 1..<31
        let dayOfMonth = cal.component(.day, from: Date())
        let remaining = max(0, monthRange.upperBound - dayOfMonth - 1)
        let monthToDate = series.reduce(0.0) { acc, point in
            cal.isDate(point.date, equalTo: Date(), toGranularity: .month) ? acc + point.cost : acc
        }
        let projection = monthToDate + last7 * Double(remaining)

        let denom = Double(totalInput + totalCacheRead)
        let hitRate = denom > 0 ? Double(totalCacheRead) / denom : 0
        let ranking = projectCosts
            .map { (name: $0.key, cost: $0.value) }
            .sorted { $0.cost > $1.cost }
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

    /// Parses a single JSONL file and stores its aggregate in `fullScanCaches`. Caller is
    /// responsible for the cache-validity check; this always re-reads from byte 0.
    private func refreshFullScanCache(filePath: String, mtime: Date, size: UInt64,
                                      heuristicGroup: String, calendar cal: Calendar) {
        autoreleasepool {
            guard let fh = FileHandle(forReadingAtPath: filePath) else { return }
            defer { try? fh.close() }
            guard let data = try? fh.readToEnd(), !data.isEmpty else {
                // Empty file — record a stub cache so we don't keep re-trying.
                var stub = FullFileCache()
                stub.mtime = mtime
                stub.size = size
                stub.groupKey = heuristicGroup
                fullScanCaches[filePath] = stub
                fileOffsets[filePath] = size
                return
            }

            var cache = FullFileCache()
            cache.mtime = mtime
            cache.size = UInt64(data.count)
            var fileCwd: String? = nil

            let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
            for line in lines {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

                if fileCwd == nil, let cwd = json["cwd"] as? String {
                    fileCwd = cwd
                }

                guard let message = json["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      let usageDict = message["usage"] as? [String: Any],
                      let pricing = ModelPricing.forModel(model) else { continue }

                guard let timestamp = json["timestamp"] as? String,
                      let d = Self.isoFormatter.date(from: timestamp) else { continue }

                let inputTokens = usageDict["input_tokens"] as? Int ?? 0
                let outputTokens = usageDict["output_tokens"] as? Int ?? 0
                let cacheWrite = usageDict["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
                let cacheWrite1h = (usageDict["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0

                let usage = TokenUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheWriteTokens: cacheWrite,
                    cacheReadTokens: cacheRead,
                    cacheWrite1hTokens: cacheWrite1h
                )
                let cost = usage.cost(for: model)
                let toks = usage.totalTokens

                cache.totalCost += cost
                cache.totalTokens += toks
                cache.totalCalls += 1
                cache.sessionModels.insert(model)

                if var existing = cache.modelTokens[model] {
                    existing.input += inputTokens
                    existing.output += outputTokens
                    existing.cacheWrite += cacheWrite
                    existing.cacheRead += cacheRead
                    existing.cost += cost
                    cache.modelTokens[model] = existing
                } else {
                    cache.modelTokens[model] = (inputTokens, outputTokens, cacheWrite, cacheRead, cost)
                }

                cache.totalCacheRead += cacheRead
                cache.totalInput += inputTokens
                cache.savings += Double(cacheRead) * (pricing.inputPerMillion - pricing.cacheReadPerMillion) / 1_000_000.0

                let day = cal.startOfDay(for: d)
                if var existing = cache.perDay[day] {
                    existing.cost += cost
                    existing.tokens += toks
                    existing.calls += 1
                    cache.perDay[day] = existing
                } else {
                    cache.perDay[day] = (cost, toks, 1)
                }

                let weekday = (cal.component(.weekday, from: d) + 5) % 7
                let hour = cal.component(.hour, from: d)
                cache.heat[weekday][hour] += cost
            }

            cache.groupKey = fileCwd.map(ProjectGroup.groupName(fromRealPath:)) ?? heuristicGroup
            fullScanCaches[filePath] = cache
            fileOffsets[filePath] = cache.size
        }
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
        var deltaUsages: [(TokenUsage, String)] = []
        let sampleAt = Date()

        for session in bgActiveSessions {
            let encodedCwd = session.cwd
                .replacingOccurrences(of: "/", with: "-")
            let dirPath = claudeDir + "/projects/" + encodedCwd

            // Match both `<sessionId>.jsonl` (main transcript) and `<sessionId>/subagents/*.jsonl`
            // (Agent-tool sub-runs) — both contain the session id somewhere in the path.
            for filePath in enumerateJSONLs(in: dirPath) where filePath.contains(session.sessionId) {
                let offset = fileOffsets[filePath] ?? 0
                let (usages, newOffset) = parseJSONL(at: filePath, fromOffset: offset)
                fileOffsets[filePath] = newOffset
                deltaUsages.append(contentsOf: usages)
            }
        }

        guard !deltaUsages.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (usage, model) in deltaUsages {
                self.modelUsage.add(usage: usage, model: model)
                self.totalCost += usage.cost(for: model)
                self.totalTokens += usage.totalTokens
                self.burnRateTracker.addSample(tokens: usage.totalTokens, at: sampleAt)
            }
        }
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

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Runs on analyticsQueue. Incremental: per-file cache keyed by path stores (mtime, offset, aggregates).
    /// On each tick, we only re-read files whose mtime advanced, and only the bytes appended since the
    /// last read. This replaces the previous full-file rescan that was burning ~25 MB/s on the main
    /// thread.
    func computeTodaySummaries() {
        let projectsDir = claudeDir + "/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return }

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())

        // Day rolled over → discard yesterday's caches.
        if todayCacheDay != todayStart {
            todayFileCaches.removeAll()
            todayCacheDay = todayStart
        }

        var seenFiles: Set<String> = []

        for dir in dirs {
            if let group = selectedGroup {
                let decoded = ProjectGroup.decodePath(dir)
                let dirGroup = ProjectGroup.groupName(from: decoded)
                if dirGroup != group { continue }
            }
            let dirPath = projectsDir + "/" + dir
            for filePath in enumerateJSONLs(in: dirPath) {
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
                if currentSize < cache.offset {
                    cache = TodayFileCache()
                }

                autoreleasepool {

                guard let fh = FileHandle(forReadingAtPath: filePath) else { return }
                defer { try? fh.close() }
                do { try fh.seek(toOffset: cache.offset) } catch { return }
                guard let data = try? fh.readToEnd(), !data.isEmpty else {
                    cache.mtime = mtime
                    todayFileCaches[filePath] = cache
                    return
                }
                let newOffset = cache.offset + UInt64(data.count)

                let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
                for line in lines {
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let message = json["message"] as? [String: Any],
                          let model = message["model"] as? String,
                          let usageDict = message["usage"] as? [String: Any],
                          ModelPricing.forModel(model) != nil else { continue }

                    // Skip entries from before today (file may straddle midnight on first scan).
                    if let timestamp = json["timestamp"] as? String,
                       let date = Self.isoFormatter.date(from: timestamp),
                       date < todayStart {
                        continue
                    }

                    let inputTokens = usageDict["input_tokens"] as? Int ?? 0
                    let outputTokens = usageDict["output_tokens"] as? Int ?? 0
                    let cacheWrite = usageDict["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
                    let cacheWrite1h = (usageDict["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0

                    let usage = TokenUsage(
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheWriteTokens: cacheWrite,
                        cacheReadTokens: cacheRead,
                        cacheWrite1hTokens: cacheWrite1h
                    )
                    let lineCost = usage.cost(for: model)
                    cache.cost += lineCost
                    cache.tokens += usage.totalTokens
                    cache.calls += 1

                    if (json["type"] as? String) == "assistant" {
                        var toolNames: [String] = []
                        if let content = message["content"] as? [[String: Any]] {
                            for block in content {
                                if let blockType = block["type"] as? String, blockType == "tool_use",
                                   let name = block["name"] as? String {
                                    toolNames.append(name)
                                }
                            }
                        }
                        let category = ActivityCategory.classify(tools: toolNames)
                        cache.activity.add(category: category, cost: lineCost, tokens: usage.totalTokens)
                    }
                }

                cache.offset = newOffset
                cache.mtime = mtime
                todayFileCaches[filePath] = cache

                } // autoreleasepool
            }
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
            sumActivity.merge(c.activity)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.todayCost = sumCost
            self.todayTokens = sumTokens
            self.todayCalls = sumCalls
            self.todayActivity = sumActivity
        }
    }

    private func parseJSONL(at path: String, fromOffset: UInt64) -> ([(TokenUsage, String)], UInt64) {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return ([], fromOffset) }
        defer { try? fileHandle.close() }

        fileHandle.seek(toFileOffset: fromOffset)
        guard let data = try? fileHandle.readToEnd(), !data.isEmpty else {
            return ([], fromOffset)
        }

        let newOffset = fromOffset + UInt64(data.count)
        var results: [(TokenUsage, String)] = []
        let filterStart = dateFilter.startDate

        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usageDict = message["usage"] as? [String: Any] else { continue }

            // Skip synthetic/unknown models
            guard ModelPricing.forModel(model) != nil else { continue }

            // Apply date filter
            if let filterStart = filterStart,
               let timestamp = json["timestamp"] as? String,
               let date = Self.isoFormatter.date(from: timestamp),
               date < filterStart {
                continue
            }

            let inputTokens = usageDict["input_tokens"] as? Int ?? 0
            let outputTokens = usageDict["output_tokens"] as? Int ?? 0
            let cacheWrite = usageDict["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usageDict["cache_read_input_tokens"] as? Int ?? 0
            let cacheWrite1h = (usageDict["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0

            let usage = TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheWriteTokens: cacheWrite,
                cacheReadTokens: cacheRead,
                cacheWrite1hTokens: cacheWrite1h
            )
            results.append((usage, model))
        }

        return (results, newOffset)
    }


    func applyFilter(_ group: String?) {
        selectedGroup = group
        burnRateTracker = BurnRateTracker()
        analyticsQueue.async { [weak self] in
            guard let self else { return }
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
