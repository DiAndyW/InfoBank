import Foundation
import GRDB

public enum ItemActionError: Error, Equatable, LocalizedError {
    case notFound, topicUnavailable, conflictSettled

    public var errorDescription: String? {
        switch self {
        case .notFound: "This Item is no longer available."
        case .topicUnavailable: "This Topic was archived or deleted. Choose another destination."
        case .conflictSettled: "This conflict was already settled."
        }
    }
}

public struct TextConflict: Hashable, Sendable {
    public let text: String?
    public let mine: Bool
}

extension Store {
    public func move(itemID: String, to destination: Destination, nowUs: Int64) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT deleted_at IS NULL AND sync_error IS NULL FROM items WHERE id = ?", arguments: [itemID]) == true else {
                throw ItemActionError.notFound
            }
            var topicID: String?
            if case .topic(let id) = destination {
                guard try Bool.fetchOne(db, sql: "SELECT archived_at IS NULL AND deleted_at IS NULL FROM topics WHERE id = ?", arguments: [id]) == true else {
                    throw ItemActionError.topicUnavailable
                }
                topicID = id
            }
            try db.execute(sql: "UPDATE items SET topic_id = ?, in_tunnel = ? WHERE id = ?", arguments: [topicID, destination == .tunnel, itemID])
            try queue(db, "MoveItem", nowUs: nowUs, ["item_id": itemID, "topic_id": topicID as Any? ?? NSNull(), "tunnel": destination == .tunnel])
        }
    }

    @discardableResult
    public func editText(itemID: String, text: String, baseRev: Int64, nowUs: Int64) throws -> Bool {
        try pool.write { try editText($0, itemID: itemID, text: text, baseRev: baseRev, nowUs: nowUs) }
    }

    private func editText(_ db: Database, itemID: String, text: String, baseRev: Int64, nowUs: Int64) throws -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Self.maxItemTextBytes else { throw CaptureError.tooLong }
        guard !text.utf8.contains(0) else { throw CaptureError.unsavableCharacter }
        guard let item = try Row.fetchOne(db, sql: "SELECT text FROM items WHERE id = ? AND deleted_at IS NULL AND sync_error IS NULL", arguments: [itemID]) else {
            throw ItemActionError.notFound
        }
        try db.execute(sql: "DELETE FROM conflicts WHERE item_id = ?", arguments: [itemID])
        if try text.isEmpty && (Int.fetchOne(db, sql: "SELECT count(*) FROM attachments WHERE item_id = ?", arguments: [itemID])) == 0 {
            try db.execute(sql: "UPDATE items SET deleted_at = ? WHERE id = ?", arguments: [nowUs, itemID])
            try queue(db, "TrashItem", nowUs: nowUs, ["item_id": itemID])
            return true
        }
        let next = text.isEmpty ? nil : text
        let previous: String? = item["text"]
        if next != previous {
            try db.execute(sql: "UPDATE items SET text = ? WHERE id = ?", arguments: [next, itemID])
            try queue(db, "SetText", nowUs: nowUs, ["item_id": itemID, "text": next as Any? ?? NSNull(), "base_rev": baseRev])
        }
        return false
    }

    @discardableResult
    public func resolveTextConflict(itemID: String, keepMine: Bool, nowUs: Int64) throws -> Bool {
        try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT text, mine FROM conflicts WHERE item_id = ?", arguments: [itemID]) else {
                throw ItemActionError.conflictSettled
            }
            let mine: Bool = row["mine"]
            if mine != keepMine {
                try db.execute(sql: "DELETE FROM conflicts WHERE item_id = ?", arguments: [itemID])
                return false
            }
            guard let revision = try Int64.fetchOne(db, sql: "SELECT text_rev FROM items WHERE id = ?", arguments: [itemID]) else { throw ItemActionError.notFound }
            return try editText(db, itemID: itemID, text: row["text"] as String? ?? "", baseRev: revision, nowUs: nowUs)
        }
    }
}
