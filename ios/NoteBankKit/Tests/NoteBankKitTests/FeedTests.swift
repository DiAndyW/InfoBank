import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct FeedTests {
    private func seed(_ store: Store, topics: [(String, String)] = [], items: [(id: String, time: Int64, topic: String?)]) throws {
        try store.pool.write { db in
            for (id, name) in topics {
                try db.execute(sql: "INSERT INTO topics (id, name) VALUES (?, ?)", arguments: [id, name])
            }
            for item in items {
                try db.execute(
                    sql: "INSERT INTO items (id, topic_id, text, capture_time) VALUES (?, ?, ?, ?)",
                    arguments: [item.id, item.topic, "text \(item.id)", item.time])
            }
        }
    }

    private func ids(_ items: [FeedItem]) -> [String] { items.map(\.id) }

    @Test func anItemsLabelIsItsFirstWordsOrFilename() throws {
        let (store, _) = try tempStore()
        try seed(store, items: [("a", 1, nil)])
        try store.pool.write { try $0.execute(sql: "INSERT INTO attachments VALUES ('x', 'a', 'f.txt', 'text/plain', 3, 1, 0)") }
        #expect(try store.items(in: .all, before: nil, limit: 1)[0].label == "text a")
        try store.pool.write { try $0.execute(sql: "UPDATE items SET text = NULL") }
        #expect(try store.items(in: .all, before: nil, limit: 1)[0].label == "f.txt")
    }

    @Test func eachPlaceShowsItsItems() throws {
        let (store, _) = try tempStore()
        try seed(store, topics: [("t1", "Mosaic")], items: [("a", 1, nil), ("b", 2, "t1"), ("c", 3, nil)])
        #expect(ids(try store.items(in: .all, before: nil, limit: 100)) == ["c", "b", "a"])
        #expect(ids(try store.items(in: .inbox, before: nil, limit: 100)) == ["c", "a"])
        #expect(ids(try store.items(in: .topic("t1"), before: nil, limit: 100)) == ["b"])
    }

    @Test func newestFirstAndTrashHidden() throws {
        let (store, _) = try tempStore()
        try seed(store, items: [("a", 2, nil), ("b", 3, nil), ("c", 1, nil), ("d", 4, nil)])
        try store.pool.write { try $0.execute(sql: "UPDATE items SET deleted_at = 9 WHERE id = 'd'") }
        #expect(ids(try store.items(in: .all, before: nil, limit: 100)) == ["b", "a", "c"])
        #expect(ids(try store.items(in: .inbox, before: nil, limit: 100)) == ["b", "a", "c"])
        #expect(ids(try store.items(in: .all, before: nil, limit: 2)) == ["b", "a"])
    }

    @Test func aPageBoundaryWithEqualTimesSkipsNothing() throws {
        let (store, _) = try tempStore()
        try seed(store, items: ["1", "2", "3", "4", "5"].map { ($0, 7, nil) })
        var seen: [String] = []
        var cursor: FeedCursor?
        while true {
            let page = try store.items(in: .all, before: cursor, limit: 2)
            if page.isEmpty { break }
            seen += ids(page)
            cursor = page.last?.cursor
        }
        #expect(seen == ["5", "4", "3", "2", "1"])
    }

    @Test func theLoadedRangeRefetchIncludesNewItemsAndKeepsOlderOnes() throws {
        let (store, _) = try tempStore()
        try seed(store, items: [("a", 1, nil), ("b", 2, nil), ("c", 3, nil)])
        let loaded = try store.items(in: .all, before: nil, limit: 2)
        #expect(ids(loaded) == ["c", "b"])
        try seed(store, items: [("d", 4, nil), ("e", 25, nil)])
        let last = try #require(loaded.last).cursor
        #expect(ids(try store.items(in: .all, from: last)) == ["e", "d", "c", "b"])
        try seed(store, items: [("f", 2, nil)])
        #expect(ids(try store.items(in: .all, from: last)) == ["e", "d", "c", "f", "b"])
    }

    @Test func pendingFollowsTheOutboxAndSyncErrorClearsIt() throws {
        let (store, _) = try tempStore()
        try seed(store, items: [("pulled", 1, nil)])
        let captured = try store.capture(text: "mine", topicID: nil, nowUs: 2)
        let pending = { try store.items(in: .all, before: nil, limit: 100).map { [$0.id: $0.pending] }.reduce(into: [:]) { $0.merge($1) { a, _ in a } } }
        #expect(try pending() == ["pulled": false, captured: true])

        try store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = 'invalid' WHERE id = ?", arguments: [captured]) }
        let item = try #require(try store.items(in: .all, before: nil, limit: 100).first)
        #expect(item.id == captured && !item.pending && item.syncError == "invalid")

        try store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = NULL; DELETE FROM outbox") }
        #expect(try pending() == ["pulled": false, captured: false])
    }

    @Test func topicNameAndAttachmentNamesAreFilled() throws {
        let (store, _) = try tempStore()
        try seed(store, topics: [("t1", "Mosaic")], items: [("a", 1, "t1"), ("b", 2, nil)])
        try store.pool.write { db in
            for (id, name) in [("x1", "one.png"), ("x2", "two.pdf")] {
                try db.execute(
                    sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?, 'a', ?, 'x/y', 1, 1, 0)",
                    arguments: [id, name])
            }
        }
        let items = try store.items(in: .all, before: nil, limit: 100)
        let b = items[0], a = items[1]
        #expect(b.topicID == nil && b.topicName == nil && b.attachmentNames == [])
        #expect(a.topicID == "t1" && a.topicName == "Mosaic" && a.attachmentNames == ["one.png", "two.pdf"])
        #expect(a.cursor == FeedCursor(captureTimeUs: 1, id: "a"))
        #expect(a.text == "text a" && a.captureTimeUs == 1)
    }

    @Test func placesCountsSortsAndHidesArchived() throws {
        let (store, _) = try tempStore()
        try seed(
            store,
            topics: [("t10", "Topic 10"), ("t2", "Topic 2"), ("m", "Mosaic"), ("c", "cs 111"), ("arch", "Archived"), ("gone", "Deleted")],
            items: [("1", 1, nil), ("2", 2, "m"), ("3", 3, "m"), ("4", 4, "t2"), ("5", 5, "arch"), ("6", 6, nil), ("7", 7, "m")])
        try store.pool.write { db in
            try db.execute(sql: "UPDATE topics SET archived_at = 1 WHERE id = 'arch'; UPDATE topics SET deleted_at = 1 WHERE id = 'gone'")
            try db.execute(sql: "UPDATE items SET deleted_at = 9 WHERE id IN ('6', '7')")
        }
        let places = try store.places()
        #expect(places.allCount == 5)
        #expect(places.inboxCount == 1)
        #expect(places.topics == [
            TopicPlace(id: "c", name: "cs 111", count: 0),
            TopicPlace(id: "m", name: "Mosaic", count: 2),
            TopicPlace(id: "t2", name: "Topic 2", count: 1),
            TopicPlace(id: "t10", name: "Topic 10", count: 0),
        ])
    }
}
