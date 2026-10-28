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

    func editText(_ db: Database, itemID: String, text: String, baseRev: Int64, nowUs: Int64) throws -> Bool {
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

extension Store {
    @discardableResult
    public func editItem(itemID: String, text: String, baseRev: Int64, adding: [String], removing: Set<String>, nowUs: Int64) throws -> Bool {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT deleted_at IS NULL AND sync_error IS NULL FROM items WHERE id = ?", arguments: [itemID]) == true else { throw ItemActionError.notFound }
            guard Set(adding).count == adding.count else { throw AttachmentError("Choose each Attachment once") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf8.count <= Self.maxItemTextBytes else { throw CaptureError.tooLong }
            guard !trimmed.utf8.contains(0) else { throw CaptureError.unsavableCharacter }
            let existing = Set(try String.fetchAll(db, sql: "SELECT id FROM attachments WHERE item_id = ?", arguments: [itemID]))
            let removed = removing.intersection(existing)
            if trimmed.isEmpty && existing.subtracting(removed).isEmpty && adding.isEmpty {
                try db.execute(sql: "UPDATE items SET deleted_at = ?, purge_at = NULL WHERE id = ?", arguments: [nowUs,itemID])
                try queue(db, "TrashItem", nowUs: nowUs, ["item_id":itemID])
                return true
            }
            for id in adding {
                guard let row = try Row.fetchOne(db, sql: "SELECT s.*, c.path FROM staged_files s JOIN cached_files c ON c.attachment_id = s.id AND c.kind = 'file' WHERE s.id = ?", arguments: [id]), FileManager.default.fileExists(atPath: directory.appending(path: row["path"] as String).path) else { throw AttachmentError("An Attachment is no longer available") }
                let a: [String: Any] = ["id":id,"filename":row["filename"] as String,"mime_type":row["mime_type"] as String,"size_bytes":row["size_bytes"] as Int64]
                try db.execute(sql: "INSERT INTO attachments VALUES (?,?,?,?,?,0,0)", arguments: [id,itemID,row["filename"] as String,row["mime_type"] as String,row["size_bytes"] as Int64])
                try db.execute(sql: "DELETE FROM staged_files WHERE id = ?", arguments: [id])
                try queue(db, "AddAttachment", nowUs: nowUs, ["item_id":itemID,"attachment":a])
            }
            // SetText runs before removals so the Server never observes a transient empty Item.
            _ = try editText(db, itemID: itemID, text: text, baseRev: baseRev, nowUs: nowUs)
            for id in removed {
                try db.execute(sql: "DELETE FROM attachments WHERE id = ? AND item_id = ?", arguments: [id,itemID])
                try queue(db, "RemoveAttachment", nowUs: nowUs, ["item_id":itemID,"attachment_id":id])
            }
            return false
        }
    }
}
