import Foundation
import Testing
@testable import NoteBankKit

struct QuickCaptureTests {
    @Test func quickPlacesUseThePlacesRanking() throws {
        let (store, _) = try tempStore()
        try store.pool.write { db in
            for name in ["b-empty", "A-empty", "old", "new", "trashed-only", "mixed"] {
                try db.execute(sql: "INSERT INTO topics (id, name, activity_at) VALUES (?, ?, ?)", arguments: [name, name, ["b-empty": 100, "A-empty": 100, "old": 10, "new": 30, "trashed-only": 50, "mixed": 90][name]!])
            }
            for (id, topic, time, deleted) in [("o", "old", 10, false), ("n", "new", 30, false), ("t", "trashed-only", 50, true), ("m", "mixed", 20, false), ("mt", "mixed", 90, true)] {
                try db.execute(sql: "INSERT INTO items (id, topic_id, text, capture_time, deleted_at) VALUES (?, ?, 'text', ?, ?)", arguments: [id, topic, time, deleted ? 1 : nil])
            }
        }
        let places = try store.quickPlaces()
        #expect(places.map(\.name) == ["Inbox", "Tunnel", "A-empty", "b-empty", "mixed", "trashed-only", "new", "old"])
        #expect(places.map(\.lastUsedUs) == [nil, nil, 100, 100, 90, 50, 30, 10])
        #expect(Array(places.dropFirst(2)).map(\.name) == (try store.places()).topics.map(\.name))
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

    @Test func quickPlaceRejectsDeletedAndMissingTopics() throws {
        let store = try tempStore().store
        let active = try store.createTopic(name: "Active", nowUs: 1)
        let deleted = try store.createTopic(name: "Deleted", nowUs: 1)
        try store.deleteTopic(deleted, keeping: .all, nowUs: 3)

        for closed in [Destination.topic(deleted), .topic("missing")] {
            #expect(try store.quickPlace(closed) == nil)
        }
        #expect(try store.quickPlace(.inbox)?.name == "Inbox")
        #expect(try store.quickPlace(.tunnel)?.name == "Tunnel")
        #expect(try store.quickPlace(.topic(active))?.name == "Active")
    }

    @Test func placeNameCoversClosedAndMissingTopics() throws {
        let store = try tempStore().store
        let active = try store.createTopic(name: "Active", nowUs: 1)
        let deleted = try store.createTopic(name: "Deleted", nowUs: 1)
        try store.deleteTopic(deleted, keeping: .all, nowUs: 3)

        #expect(try store.placeName(.inbox) == "Inbox")
        #expect(try store.placeName(.tunnel) == "Tunnel")
        #expect(try store.placeName(.topic(active)) == "Active")
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
    @Test @MainActor func successfulDraftSaveClearsSuspensionError() throws {
        let store = try Store(at: tempStore().file)
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        model.text = "Keep this draft"
        store.suspendFileDatabaseAccess()
        defer { store.resumeFileDatabaseAccess() }
        model.flushDraft()
        #expect(model.error == nil)
        model.flushDraft()
        #expect(model.error == nil)
        model.flushDraft()
        #expect(model.error == "Couldn't save your draft. Your text is still here.")
        store.resumeFileDatabaseAccess()
        model.flushDraft()
        #expect(try store.drafts()[.inbox]?.text == "Keep this draft")
        #expect(model.error == nil)
        store.suspendFileDatabaseAccess()
        model.flushDraft()
        #expect(model.error == nil)
        model.reportImportError("Send failed")
        model.flushDraft()
        model.flushDraft()
        #expect(model.error == "Send failed")
        #expect(!model.send())
        model.flushDraft()
        model.flushDraft()
        #expect(model.error == "NoteBank couldn't read or save its data. Try again.")
        store.resumeFileDatabaseAccess()
        model.flushDraft()
        #expect(model.error == "NoteBank couldn't read or save its data. Try again.")
    }

    @Test @MainActor func sendDatabaseFailureIsPlain() throws {
        let store = try Store(at: tempStore().file)
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        model.text = "keep"
        store.suspendFileDatabaseAccess()
        defer { store.resumeFileDatabaseAccess() }
        #expect(!model.send())
        #expect(model.error == "NoteBank couldn't read or save its data. Try again.")
        #expect(model.text == "keep")
    }

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
