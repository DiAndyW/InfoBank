import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct CaptureTests {
    private func counts(_ store: Store) throws -> (items: Int, ops: Int) {
        try store.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM items")!, try Int.fetchOne(db, sql: "SELECT count(*) FROM outbox")!)
        }
    }

    @Test func aTunnelCaptureIsFlaggedOnTheItemAndItsOp() throws {
        let (store, _) = try tempStore()
        let id = try store.capture(text: "for my other device", to: .tunnel, nowUs: 1)
        let (inTunnel, topicID, ops) = try store.pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT in_tunnel, topic_id FROM items WHERE id = ?", arguments: [id])!
            return (row["in_tunnel"] as Int, row["topic_id"] as String?, try String.fetchAll(db, sql: "SELECT op FROM outbox"))
        }
        #expect(inTunnel == 1 && topicID == nil)
        let op = try #require(JSONSerialization.jsonObject(with: Data(ops[0].utf8)) as? [String: Any])
        #expect(op["tunnel"] as? Bool == true)
        #expect(op["topic_id"] is NSNull)
    }

    @Test func theLocalSchemaRefusesATunnelItemInATopic() throws {
        let (store, _) = try tempStore()
        #expect(throws: DatabaseError.self) {
            try store.pool.write {
                try $0.execute(sql: "INSERT INTO items (id, topic_id, text, capture_time, in_tunnel) VALUES ('a', 't1', 'x', 1, 1)")
            }
        }
    }

    @Test func aCaptureWritesTheItemAndItsOpTogether() throws {
        let (store, _) = try tempStore()
        let now: Int64 = 1_760_000_000_123_456
        let id = try store.capture(text: "buy milk", to: .topic("t1"), nowUs: now)
        let (captureTime, text, topicID, ops) = try store.pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT capture_time, text, topic_id FROM items WHERE id = ?", arguments: [id])!
            return (row["capture_time"] as Int64, row["text"] as String, row["topic_id"] as String?, try String.fetchAll(db, sql: "SELECT op FROM outbox"))
        }
        #expect(captureTime == now)
        #expect(text == "buy milk")
        #expect(topicID == "t1")
        #expect(ops.count == 1)
        let op = try #require(JSONSerialization.jsonObject(with: Data(ops[0].utf8)) as? [String: Any])
        #expect(op["type"] as? String == "CaptureItem")
        #expect(op["item_id"] as? String == id)
        #expect(op["topic_id"] as? String == "t1")
        #expect(op["text"] as? String == "buy milk")
        #expect((op["attachments"] as? [Any])?.isEmpty == true)
        #expect(op["at"] as? String == Time.rfc3339(captureTime))
        #expect((op["id"] as? String)?.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
        #expect(Set(op.keys) == ["id", "type", "at", "item_id", "topic_id", "text", "attachments"])
    }

    @Test func anInboxCaptureHasANullTopic() throws {
        let (store, _) = try tempStore()
        _ = try store.capture(text: "a", to: .inbox, nowUs: 1)
        let op = try store.pool.read { try String.fetchOne($0, sql: "SELECT op FROM outbox")! }
        let json = try #require(JSONSerialization.jsonObject(with: Data(op.utf8)) as? [String: Any])
        #expect(json["topic_id"] is NSNull)
    }

    @Test func textIsTrimmed() throws {
        let (store, _) = try tempStore()
        let id = try store.capture(text: " \n hello world \t\n", to: .inbox, nowUs: 1)
        let text = try store.pool.read { try String.fetchOne($0, sql: "SELECT text FROM items WHERE id = ?", arguments: [id])! }
        #expect(text == "hello world")
        let op = try store.pool.read { try String.fetchOne($0, sql: "SELECT json_extract(op, '$.text') FROM outbox")! }
        #expect(op == "hello world")
    }

    @Test func blankTooLongAndNULAreRejectedWithNothingWritten() throws {
        let (store, _) = try tempStore()
        let limit = 1 << 20
        for (text, error) in [
            ("   \n", CaptureError.blank),
            ("", .blank),
            (String(repeating: "a", count: limit + 1), .tooLong),
            (String(repeating: "é", count: limit / 2 + 1), .tooLong),
            ("a\0b", .unsavableCharacter),
        ] {
            #expect(throws: error) { try store.capture(text: text, to: .inbox, nowUs: 1) }
            let (items, ops) = try counts(store)
            #expect(items == 0 && ops == 0)
        }
        _ = try store.capture(text: String(repeating: "a", count: limit), to: .inbox, nowUs: 1)
        #expect(try counts(store) == (1, 1))
    }

    @Test func errorsCarryTheExactCopy() {
        #expect(CaptureError.blank.errorDescription == "Write something first")
        #expect(CaptureError.tooLong.errorDescription == "That's too long to save (1 MB max)")
        #expect(CaptureError.unsavableCharacter.errorDescription == "That text contains a character that can't be saved")
        #expect(CaptureError.notRefused.errorDescription == "Only an Item the Server refused can be discarded")
    }

    @Test func discardOnlyWorksOnARefusedCapture() throws {
        let (store, _) = try tempStore()
        let id = try store.capture(text: "mine", to: .inbox, nowUs: 1)
        try store.pool.write {
            try $0.execute(sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES ('a1', ?, 'f.txt', 'text/plain', 1, 0, 0)", arguments: [id])
        }
        #expect(throws: CaptureError.notRefused) { try store.discard(itemID: id) }
        #expect(try counts(store) == (1, 1))

        try store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = 'invalid'") }
        try store.discard(itemID: id)
        #expect(try counts(store) == (0, 0))
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM attachments")! } == 0)
    }

    @Test func discardLeavesOtherItemsAlone() throws {
        let (store, _) = try tempStore()
        let refused = try store.capture(text: "one", to: .inbox, nowUs: 1)
        _ = try store.capture(text: "two", to: .inbox, nowUs: 2)
        try store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = 'invalid' WHERE id = ?", arguments: [refused]) }
        try store.discard(itemID: refused)
        #expect(try counts(store) == (1, 1))
    }
}
