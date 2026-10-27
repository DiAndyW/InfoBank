import Foundation
import GRDB

extension Store {
    func queue(_ db: Database, _ type: String, nowUs: Int64, _ fields: [String: Any]) throws {
        let op = try JSONSerialization.data(
            withJSONObject: fields.merging(["id": UUID().uuidString.lowercased(), "type": type, "at": Time.rfc3339(nowUs)]) { $1 },
            options: [.withoutEscapingSlashes])
        try db.execute(sql: "INSERT INTO outbox (op) VALUES (?)", arguments: [String(decoding: op, as: UTF8.self)])
    }

    public func trash(itemID: String, nowUs: Int64) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT sync_error IS NULL FROM items WHERE id = ?", arguments: [itemID]) == true else { throw ItemActionError.notFound }
            try db.execute(sql: "UPDATE items SET deleted_at = ? WHERE id = ?", arguments: [nowUs, itemID])
            try queue(db, "TrashItem", nowUs: nowUs, ["item_id": itemID])
        }
    }

    public func restore(itemID: String, nowUs: Int64) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT sync_error IS NULL FROM items WHERE id = ?", arguments: [itemID]) == true else { throw ItemActionError.notFound }
            try db.execute(sql: "UPDATE items SET deleted_at = NULL, purge_at = NULL WHERE id = ?", arguments: [itemID])
            try queue(db, "RestoreItem", nowUs: nowUs, ["item_id": itemID])
        }
    }

    public func trashAfterCopy() throws -> Bool? {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(
                        (SELECT json_extract(op, '$.value') FROM outbox WHERE json_extract(op, '$.type') = 'SetTrashAfterCopy' ORDER BY seq DESC LIMIT 1),
                        (SELECT trash_after_copy FROM settings))
                    """)
        }
    }

    public func setTrashAfterCopy(_ on: Bool, nowUs: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE settings SET trash_after_copy = ?", arguments: [on])
            try db.execute(sql: "DELETE FROM outbox WHERE json_extract(op, '$.type') = 'SetTrashAfterCopy'")
            try queue(db, "SetTrashAfterCopy", nowUs: nowUs, ["value": on])
        }
    }
}
