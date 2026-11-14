import Foundation
import GRDB
import Testing
@testable import NoteBankKit

@MainActor
struct SearchModelTests {
    private static let newYork = TimeZone(identifier: "America/New_York")!

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func utcUs(_ rfc3339: String) -> Int64 { Time.micros(rfc3339: rfc3339)! }

    private func model(_ store: Store, place: SearchPlace = .all, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> SearchModel {
        SearchModel(store: store, place: place, calendar: calendar(), now: { now }, debounce: .milliseconds(20))
    }

    private func put(_ store: Store, _ id: String, _ text: String, at captureTimeUs: Int64 = 1, files: Bool = false) throws {
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES (?, ?, ?)", arguments: [id, text, captureTimeUs])
            if files {
                try db.execute(
                    sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?, ?, 'a.pdf', 'application/pdf', 1, 1, 0)",
                    arguments: ["\(id)-f", id])
            }
        }
    }

    @Test func typingSearchesAfterThePause() async throws {
        let (store, _) = try tempStore()
        try put(store, "a", "the invoice")
        let search = model(store)
        search.text = "invoice"
        #expect(search.results.isEmpty)
        #expect(await waitUntil { search.results.map(\.id) == ["a"] })
    }

    @Test func aNewerKeystrokeCancelsThePendingRun() async throws {
        let (store, _) = try tempStore()
        try put(store, "a", "the invoice")
        let search = model(store)
        search.text = "inv"
        search.text = "zzz"
        #expect(await waitUntil { search.isEmptyResult })
        #expect(search.results.isEmpty)
        try await Task.sleep(for: .milliseconds(80))
        #expect(search.results.isEmpty)
    }

    @Test func filtersRunAtOnce() async throws {
        let (store, _) = try tempStore()
        try put(store, "plain", "note one", at: 1)
        try put(store, "withfile", "note two", at: 2, files: true)
        let search = model(store)
        search.text = "note"
        #expect(await waitUntil { search.results.count == 2 })
        search.hasFiles = true
        #expect(search.results.map(\.id) == ["withfile"])
        search.hasFiles = false
        #expect(search.results.count == 2)
        search.place = .inbox
        #expect(search.results.count == 2)
        search.place = .tunnel
        #expect(search.results.isEmpty)
    }

    @Test func blankTextClears() async throws {
        let (store, _) = try tempStore()
        try put(store, "a", "the invoice")
        let search = model(store)
        search.text = "invoice"
        #expect(await waitUntil { !search.results.isEmpty })
        search.text = "  "
        #expect(search.results.isEmpty)
        #expect(search.query == nil)
        #expect(!search.isEmptyResult)
        #expect(!search.hasMore)
    }

    @Test func databaseChangesRerun() async throws {
        let (store, _) = try tempStore()
        let search = model(store)
        search.text = "invoice"
        #expect(await waitUntil { search.isEmptyResult })

        let first = try store.capture(text: "invoice one", to: .inbox, nowUs: 1_000)
        #expect(await waitUntil { search.results.map(\.id) == [first] })
        let second = try store.capture(text: "invoice two", to: .inbox, nowUs: 2_000)
        #expect(await waitUntil { search.results.map(\.id) == [second, first] })

        try store.trash(itemID: second, nowUs: 3_000)
        #expect(await waitUntil { search.results.map(\.id) == [first] })
    }

    @Test func deletedPresetTopicFallsBackToAnywhere() async throws {
        let (store, _) = try tempStore()
        let topic = try store.createTopic(name: "Taxes", nowUs: 1)
        let search = model(store, place: .topic(topic))
        try store.deleteTopic(topic, keeping: .all, nowUs: 2)
        #expect(await waitUntil { search.place == .all })
    }

    @Test func presetTopicThatIsAlreadyGoneStartsAtAnywhere() throws {
        let (store, _) = try tempStore()
        let topic = try store.createTopic(name: "Taxes", nowUs: 1)
        try store.deleteTopic(topic, keeping: .all, nowUs: 2)
        #expect(model(store, place: .topic(topic)).place == .all)
    }

    @Test func livePresetTopicStays() async throws {
        let (store, _) = try tempStore()
        let topic = try store.createTopic(name: "Taxes", nowUs: 1)
        let search = model(store, place: .topic(topic))
        search.text = "invoice"
        try await store.pool.write { try $0.execute(sql: "INSERT INTO items (id, topic_id, text, capture_time) VALUES ('a', ?, 'invoice', 3)", arguments: [topic]) }
        #expect(await waitUntil { search.results.map(\.id) == ["a"] })
        #expect(search.place == .topic(topic))
    }

    @Test func presetsUseCalendarDays() throws {
        let (store, _) = try tempStore()
        func from(_ now: Date, _ dates: SearchDates) -> Int64? {
            let search = model(store, now: now)
            search.text = "x"
            search.dates = dates
            return search.query?.fromUs
        }
        let endOfMarch = date(2026, 3, 31)
        #expect(from(endOfMarch, .pastMonth) == utcUs("2026-02-28T17:00:00Z"))
        #expect(from(endOfMarch, .pastWeek) == utcUs("2026-03-24T16:00:00Z"))
        #expect(from(endOfMarch, .pastYear) == utcUs("2025-03-31T16:00:00Z"))
        #expect(from(date(2026, 3, 10), .pastWeek) == utcUs("2026-03-03T17:00:00Z"))
        #expect(from(endOfMarch, .any) == nil)
        let search = model(store, now: endOfMarch)
        search.text = "x"
        search.dates = .pastWeek
        #expect(search.query?.toUs == nil)
    }

    @Test func customRangeIsHalfOpenLocalDays() throws {
        let (store, _) = try tempStore()
        let search = model(store)
        search.text = "x"
        search.dates = .custom(from: date(2026, 10, 31, 15), to: date(2026, 11, 1, 9))
        #expect(search.query?.fromUs == utcUs("2026-10-31T04:00:00Z"))
        #expect(search.query?.toUs == utcUs("2026-11-02T05:00:00Z"))
        search.dates = .custom(from: nil, to: nil)
        #expect(search.query?.fromUs == nil)
        #expect(search.query?.toUs == nil)
    }

    @Test func clearFiltersResetsAll() throws {
        let (store, _) = try tempStore()
        let search = model(store)
        search.place = .tunnel
        search.dates = .pastYear
        search.hasFiles = true
        search.clearFilters()
        #expect(search.place == .all)
        #expect(search.dates == .any)
        #expect(!search.hasFiles)
    }

    @Test func hasFiltersReflectsChoices() throws {
        let (store, _) = try tempStore()
        let search = model(store)
        #expect(!search.hasFilters)
        search.place = .inbox
        #expect(search.hasFilters)
        search.place = .all
        search.dates = .custom(from: nil, to: nil)
        #expect(search.hasFilters)
        search.dates = .any
        search.hasFiles = true
        #expect(search.hasFilters)
        search.hasFiles = false
        #expect(!search.hasFilters)
    }

    @Test func loadMorePagesTheQueryThatProducedTheResults() async throws {
        let (store, _) = try tempStore()
        for n in 1...101 { try put(store, "inv\(n)", "invoice \(n)", at: Int64(1_000 + n)) }
        try put(store, "other", "zzz", at: 1)
        let search = model(store)
        search.text = "invoice"
        #expect(await waitUntil { search.results.count == 100 })
        search.text = "zzz"
        search.loadMore()
        #expect(search.results.count == 101)
        #expect(search.results.allSatisfy { $0.item.text!.hasPrefix("invoice") })
        #expect(await waitUntil { search.results.map(\.id) == ["other"] })
    }

    @Test func loadMorePages() async throws {
        let (store, _) = try tempStore()
        for n in 1...101 { try put(store, "i\(n)", "needle \(n)", at: Int64(n)) }
        let search = model(store)
        search.text = "needle"
        #expect(await waitUntil { search.results.count == 100 })
        #expect(search.hasMore)
        search.loadMore()
        #expect(search.results.count == 101)
        #expect(!search.hasMore)
        #expect(Set(search.results.map(\.id)).count == 101)
    }
}
