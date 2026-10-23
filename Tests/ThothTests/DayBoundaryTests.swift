// Tests/ThothTests/DayBoundaryTests.swift
import Foundation
import Testing
@testable import Thoth

/// Day buckets, rolling windows, the 30-day series and the heatmap follow the local calendar,
/// including the days a daylight-saving change makes 23 or 25 hours long. Each test pins a time
/// zone and a clock, so it runs the same on any machine and on any date.
@MainActor
@Suite(.serialized)
struct DayBoundaryTests {
    /// One response per UTC instant; `input_tokens` sets its cost (Opus 5.5: $4 / MTok), so each
    /// can be told apart in the sums.
    private struct Fixture {
        let root: URL
        let service: ClaudeDataService
        let calendar: Calendar
        let now: Date

        init(zone: String, now: String, responses: [(utc: String, input: Int)]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-days-\(UUID().uuidString)")
            let dir = root.appendingPathComponent("projects/-srv-Documents-Acme-app")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var text = ""
            for (i, r) in responses.enumerated() {
                text += #"{"type":"assistant","cwd":"/srv/Documents/Acme/app","timestamp":"\#(r.utc)","message":{"id":"msg_\#(i)","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":\#(r.input),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
                text += "\n"
            }
            let file = dir.appendingPathComponent("session.jsonl")
            try Data(text.utf8).write(to: file)
            let clock = UsageLogParser.parseTimestamp(now)!
            try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: file.path)
            self.now = clock

            let cal = Self.calendar(zone)
            calendar = cal
            service = ClaudeDataService(claudeDir: root.path, calendar: { cal }, now: { clock })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        static func calendar(_ zone: String) -> Calendar {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: zone)!
            return cal
        }

        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.startOfDay(for: calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!)
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func cost(_ input: Int) -> Double { Double(input) * 4 / 1_000_000 }

    private func series(_ s: ClaudeDataService) -> [Date: Double] {
        Dictionary(uniqueKeysWithValues: s.dailyCostSeries.map { ($0.date, $0.cost) })
    }

    private func expectWellFormedSeries(_ f: Fixture) {
        let days = f.service.dailyCostSeries.map(\.date)
        #expect(days.count == 30)
        #expect(Set(days).count == 30)
        // Every point is the start of a local day, one calendar day after the previous one.
        #expect(days.allSatisfy { f.calendar.startOfDay(for: $0) == $0 })
        for (a, b) in zip(days, days.dropFirst()) {
            #expect(f.calendar.startOfDay(for: f.calendar.date(byAdding: .day, value: 1, to: a)!) == b)
        }
        #expect(days.last == f.calendar.startOfDay(for: f.now))
    }

    /// Lisbon, Sunday 25 October 2026: 02:00 WEST becomes 01:00 WET, a 25-hour day.
    @Test func fallBackDayIsTwentyFiveHours() async throws {
        let f = try Fixture(zone: "Europe/Lisbon", now: "2026-10-31T12:00:00.000Z", responses: [
            ("2026-10-24T22:59:00.000Z", 1_000),   // Sat 24, 23:59 WEST
            ("2026-10-24T23:00:00.000Z", 2_000),   // Sun 25, 00:00 WEST
            ("2026-10-25T00:30:00.000Z", 4_000),   // Sun 25, 01:30 WEST
            ("2026-10-25T01:30:00.000Z", 8_000),   // Sun 25, 01:30 WET (the repeated hour)
            ("2026-10-25T23:59:00.000Z", 16_000),  // Sun 25, 23:59 WET
            ("2026-10-26T00:00:00.000Z", 32_000),  // Mon 26, 00:00 WET
        ])
        defer { f.remove() }
        f.service.unifiedFullScan()
        await drainMainQueue()
        let s = f.service

        expectWellFormedSeries(f)
        let byDay = series(s)
        #expect(byDay[f.day(2026, 10, 24)] == cost(1_000))
        #expect(byDay[f.day(2026, 10, 25)] == cost(2_000 + 4_000 + 8_000 + 16_000))
        #expect(byDay[f.day(2026, 10, 26)] == cost(32_000))

        // Saturday 31: "7 Days" is Sunday 25 to Saturday 31, so it starts at 00:00 WEST on the 25th.
        #expect(s.weekCalls == 5)
        #expect(abs(s.weekCost - cost(62_000)) < 1e-12)
        #expect(s.fifteenDaysCalls == 6)
        #expect(s.monthCalls == 6)
        #expect(s.allTimeCalls == 6)

        // Heatmap rows run Monday (0) to Sunday (6); both 01:30s land on Sunday 01h.
        #expect(s.heatmap[5][23] == cost(1_000))
        #expect(s.heatmap[6][0] == cost(2_000))
        #expect(s.heatmap[6][1] == cost(4_000) + cost(8_000))
        #expect(s.heatmap[6][23] == cost(16_000))
        #expect(s.heatmap[0][0] == cost(32_000))
    }

    /// Lisbon, Sunday 29 March 2026: 01:00 WET becomes 02:00 WEST, a 23-hour day.
    @Test func springForwardDayIsTwentyThreeHours() async throws {
        let f = try Fixture(zone: "Europe/Lisbon", now: "2026-04-04T12:00:00.000Z", responses: [
            ("2026-03-28T23:59:00.000Z", 1_000),   // Sat 28, 23:59 WET
            ("2026-03-29T00:00:00.000Z", 2_000),   // Sun 29, 00:00 WET
            ("2026-03-29T00:59:00.000Z", 4_000),   // Sun 29, 00:59 WET
            ("2026-03-29T01:00:00.000Z", 8_000),   // Sun 29, 02:00 WEST (01h is skipped)
            ("2026-03-29T22:59:00.000Z", 16_000),  // Sun 29, 23:59 WEST
            ("2026-03-29T23:00:00.000Z", 32_000),  // Mon 30, 00:00 WEST
        ])
        defer { f.remove() }
        f.service.unifiedFullScan()
        await drainMainQueue()
        let s = f.service

        expectWellFormedSeries(f)
        let byDay = series(s)
        #expect(byDay[f.day(2026, 3, 28)] == cost(1_000))
        #expect(byDay[f.day(2026, 3, 29)] == cost(2_000 + 4_000 + 8_000 + 16_000))
        #expect(byDay[f.day(2026, 3, 30)] == cost(32_000))
        #expect(s.weekCalls == 5) // Sunday 29 to Saturday 4 April
        #expect(s.heatmap[6][1] == 0)
        #expect(s.heatmap[6][2] == cost(8_000))
    }

    /// Santiago, 6 September 2026: clocks jump from 00:00 to 01:00, so that day has no midnight
    /// and starts at 01:00.
    @Test func dayWithoutMidnightStillHasItsBucket() async throws {
        let f = try Fixture(zone: "America/Santiago", now: "2026-09-20T15:00:00.000Z", responses: [
            ("2026-09-06T03:59:00.000Z", 1_000),   // Sat 5, 23:59 -04
            ("2026-09-06T04:30:00.000Z", 2_000),   // Sun 6, 01:30 -03
            ("2026-09-07T02:59:00.000Z", 4_000),   // Sun 6, 23:59 -03
        ])
        defer { f.remove() }
        f.service.unifiedFullScan()
        await drainMainQueue()

        expectWellFormedSeries(f)
        let byDay = series(f.service)
        #expect(byDay[f.day(2026, 9, 5)] == cost(1_000))
        #expect(byDay[f.day(2026, 9, 6)] == cost(2_000 + 4_000))
        #expect(f.service.monthCalls == 3)
    }

    /// "Today" on the 25-hour day starts at 00:00 WEST and keeps counting after 01:00 WET.
    @Test func todaySummaryCoversTheWholeFallBackDay() async throws {
        let f = try Fixture(zone: "Europe/Lisbon", now: "2026-10-25T23:30:00.000Z", responses: [
            ("2026-10-24T22:59:00.000Z", 1_000),   // yesterday
            ("2026-10-24T23:00:00.000Z", 2_000),
            ("2026-10-25T00:30:00.000Z", 4_000),
            ("2026-10-25T01:30:00.000Z", 8_000),
            ("2026-10-25T23:29:00.000Z", 16_000),
        ])
        defer { f.remove() }
        f.service.computeTodaySummaries()
        await drainMainQueue()
        #expect(f.service.todayCalls == 4)
        #expect(abs(f.service.todayCost - cost(30_000)) < 1e-12)
    }

    /// Moving to another zone re-buckets the history instead of keeping the old zone's days.
    @Test func changingTimeZoneRebucketsDays() async throws {
        // 23:30 UTC on the 20th is the 21st in Lisbon and still the 20th in New York.
        let f = try Fixture(zone: "Europe/Lisbon", now: "2026-10-23T12:00:00.000Z",
                            responses: [("2026-10-20T23:30:00.000Z", 1_000)])
        defer { f.remove() }
        final class Zone: @unchecked Sendable { var calendar = Fixture.calendar("Europe/Lisbon") }
        let zone = Zone()
        let now = f.now
        let service = ClaudeDataService(claudeDir: f.root.path, calendar: { zone.calendar }, now: { now })

        service.unifiedFullScan()
        await drainMainQueue()
        #expect(series(service)[f.day(2026, 10, 21)] == cost(1_000))

        zone.calendar = Fixture.calendar("America/New_York")
        service.unifiedFullScan() // no file changed
        await drainMainQueue()
        let ny = zone.calendar
        let day20 = ny.startOfDay(for: ny.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!)
        #expect(series(service)[day20] == cost(1_000))
        #expect(service.dailyCostSeries.reduce(0) { $0 + $1.cost } == cost(1_000))
    }
}
