import Foundation
import Testing
@testable import NoteBankKit

struct QuickCaptureTests {
    @Test func quickPlacesListEveryOpenTopicByLastUse() throws {
        let store = try tempStore().store
        let alpha = try store.createTopic(name: "Alpha", nowUs: 1)
        let beta = try store.createTopic(name: "Beta", nowUs: 1)
        _ = try store.createTopic(name: "Aardvark", nowUs: 1)
        let gamma = try store.createTopic(name: "Gamma", nowUs: 1)
        let omega = try store.createTopic(name: "Omega", nowUs: 1)
        let tie1 = try store.createTopic(name: "N10", nowUs: 1)
        let tie2 = try store.createTopic(name: "N2", nowUs: 1)
        _ = try store.capture(text: "a", to: .topic(alpha), nowUs: 100)
        _ = try store.capture(text: "b", to: .topic(beta), nowUs: 300)
        _ = try store.capture(text: "g", to: .topic(gamma), nowUs: 500)
        _ = try store.capture(text: "o", to: .topic(omega), nowUs: 600)
        _ = try store.capture(text: "t", to: .tunnel, nowUs: 200)
        let trashed = try store.capture(text: "a2", to: .topic(alpha), nowUs: 900)
        try store.trash(itemID: trashed, nowUs: 901)
        _ = try store.capture(text: "t1", to: .topic(tie1), nowUs: 400)
        _ = try store.capture(text: "t2", to: .topic(tie2), nowUs: 400)
        try store.setTopicArchived(gamma, archived: true, nowUs: 1000)
        try store.deleteTopic(omega, keeping: .none, nowUs: 1001)

        let places = try store.quickPlaces()
        #expect(places.map(\.name) == ["Inbox", "Tunnel", "N2", "N10", "Beta", "Alpha", "Aardvark"])
        #expect(places.map(\.lastUsedUs) == [nil, 200, 400, 400, 300, 100, nil])
    }

    @Test func placeIDsRoundTrip() {
        #expect(Destination.inbox.placeID == "inbox")
        #expect(Destination.tunnel.placeID == "tunnel")
        #expect(Destination.topic("abc").placeID == "topic:abc")
        #expect(Destination(placeID: "inbox") == .inbox)
        #expect(Destination(placeID: "tunnel") == .tunnel)
        #expect(Destination(placeID: "topic:abc") == .topic("abc"))
        #expect(Destination(placeID: "topic:") == nil)
        #expect(Destination(placeID: "x") == nil)
    }

    @Test func quickPlaceRejectsArchivedAndDeletedTopics() throws {
        let store = try tempStore().store
        let active = try store.createTopic(name: "Active", nowUs: 1)
        let archived = try store.createTopic(name: "Archived", nowUs: 1)
        let deleted = try store.createTopic(name: "Deleted", nowUs: 1)
        try store.setTopicArchived(archived, archived: true, nowUs: 2)
        try store.deleteTopic(deleted, keeping: .all, nowUs: 3)

        for closed in [Destination.topic(archived), .topic(deleted), .topic("missing")] {
            #expect(try store.quickPlace(closed) == nil)
        }
        #expect(try store.quickPlace(.inbox)?.name == "Inbox")
        #expect(try store.quickPlace(.tunnel)?.name == "Tunnel")
        #expect(try store.quickPlace(.topic(active))?.name == "Active")
    }

    @Test func placeNameCoversClosedAndMissingTopics() throws {
        let store = try tempStore().store
        let active = try store.createTopic(name: "Active", nowUs: 1)
        let archived = try store.createTopic(name: "Archived", nowUs: 1)
        let deleted = try store.createTopic(name: "Deleted", nowUs: 1)
        try store.setTopicArchived(archived, archived: true, nowUs: 2)
        try store.deleteTopic(deleted, keeping: .all, nowUs: 3)

        #expect(try store.placeName(.inbox) == "Inbox")
        #expect(try store.placeName(.tunnel) == "Tunnel")
        #expect(try store.placeName(.topic(active)) == "Active")
        #expect(try store.placeName(.topic(archived)) == "Archived")
        #expect(try store.placeName(.topic(deleted)) == "Deleted")
        #expect(try store.placeName(.topic("missing")) == "Removed Topic")
    }

    @Test func usedLabelFollowsTheLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        calendar.locale = Locale(identifier: "en_US")
        func us(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Int64 {
            let date = try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
            return Int64(date.timeIntervalSince1970 * 1_000_000)
        }
        let now = try us(2026, 11, 1, 0, 30)

        #expect(usedLabel(lastUsedUs: try us(2026, 11, 1, 0, 5), nowUs: now, calendar: calendar) == "Used today")
        #expect(usedLabel(lastUsedUs: try us(2026, 10, 31, 23, 50), nowUs: now, calendar: calendar) == "Used yesterday")
        #expect(usedLabel(lastUsedUs: try us(2026, 10, 24, 12, 0), nowUs: now, calendar: calendar) == "Used Oct 24")
        #expect(usedLabel(lastUsedUs: try us(2025, 12, 30, 12, 0), nowUs: now, calendar: calendar) == "Used Dec 30, 2025")
        #expect(usedLabel(lastUsedUs: nil, nowUs: now, calendar: calendar) == nil)
    }
}

// The suspend notification is process-wide, so every other Store the tests open opts out of it.
@Suite(.serialized) struct QuickCaptureSuspensionTests {
    @Test func placeQueriesStoreClosesCleanlyWhileTheAppIsSuspended() throws {
        let file = try tempStore().file
        let app = try Store(at: file)
        var places: Store? = try Store(at: file, observesSuspension: false)
        app.suspendFileDatabaseAccess()
        defer { app.resumeFileDatabaseAccess() }

        #expect(try places?.quickPlaces().map(\.name) == ["Inbox", "Tunnel"])
        places = nil

        #expect(try app.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM file_sessions") } == 1)
    }
}
