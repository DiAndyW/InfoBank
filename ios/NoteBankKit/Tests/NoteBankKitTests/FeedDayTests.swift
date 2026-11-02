import Foundation
import Testing
@testable import NoteBankKit

struct FeedDayTests {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func items(at isoTimes: [String]) throws -> [FeedItem] {
        let store = try tempStore().store
        for time in isoTimes {
            let us = Int64(try Date(time, strategy: .iso8601).timeIntervalSince1970 * 1_000_000)
            _ = try store.capture(text: time, to: .inbox, nowUs: us)
        }
        return try store.items(in: .inbox, before: nil, limit: 50).reversed()
    }

    @Test func repeatedMinuteHidesTimeUntilTheMinuteChanges() throws {
        let feed = try items(at: ["2026-11-01T09:41:05Z", "2026-11-01T09:41:59Z", "2026-11-01T09:42:00Z", "2026-11-01T09:42:30Z"])
        let days = FeedDay.group(feed, calendar: calendar("UTC"))
        #expect(days.count == 1)
        #expect(days[0].rows.map(\.showsTime) == [true, false, true, false])
    }

    @Test func firstItemOfEachDayShowsItsTime() throws {
        let feed = try items(at: ["2026-11-01T23:59:10Z", "2026-11-02T00:00:00Z", "2026-11-02T00:00:20Z"])
        let days = FeedDay.group(feed, calendar: calendar("UTC"))
        #expect(days.map { $0.rows.map(\.showsTime) } == [[true], [true, false]])
    }

    @Test func daysFollowTheDeviceZoneNotUTC() throws {
        // 23:59:30Z and 00:00:30Z are 15:59 and 16:00 on the same Los Angeles day.
        let feed = try items(at: ["2026-11-01T23:59:30Z", "2026-11-02T00:00:30Z", "2026-11-02T00:00:50Z"])
        let days = FeedDay.group(feed, calendar: calendar("America/Los_Angeles"))
        #expect(days.count == 1)
        #expect(days[0].rows.map(\.showsTime) == [true, true, false])
        #expect(FeedDay.group(feed, calendar: calendar("UTC")).count == 2)
    }

    @Test func midnightInTheDeviceZoneStartsANewDay() throws {
        // Local midnight in Tokyo is 15:00Z; both Items share a UTC day but not a Tokyo one.
        let feed = try items(at: ["2026-11-01T14:59:40Z", "2026-11-01T15:00:10Z"])
        let days = FeedDay.group(feed, calendar: calendar("Asia/Tokyo"))
        #expect(days.map { $0.rows.map(\.showsTime) } == [[true], [true]])
    }
}
