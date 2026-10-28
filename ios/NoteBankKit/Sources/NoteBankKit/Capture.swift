import Foundation
import GRDB

public enum CaptureError: Error, Equatable, LocalizedError {
    case blank, tooLong, unsavableCharacter, notRefused

    public var errorDescription: String? {
        switch self {
        case .blank: "Write something first"
        case .tooLong: "That's too long to save (1 MB max)"
        case .unsavableCharacter: "That text contains a character that can't be saved"
        case .notRefused: "Only an Item the Server refused can be discarded"
        }
    }
}

public enum Destination: Hashable, Sendable {
    case inbox, tunnel, topic(String)
}

extension Store {
    static let maxItemTextBytes = 1 << 20

    public func capture(text: String, attachmentIDs: [String] = [], to destination: Destination, nowUs: Int64) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Store.maxItemTextBytes else { throw CaptureError.tooLong }
        guard !text.utf8.contains(0) else { throw CaptureError.unsavableCharacter }
        guard !text.isEmpty || !attachmentIDs.isEmpty else { throw CaptureError.blank }

        let itemID = UUID().uuidString.lowercased()
        var topicID: String?
        if case .topic(let id) = destination { topicID = id }
        var fields: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "type": "CaptureItem",
            "at": Time.rfc3339(nowUs),
            "item_id": itemID,
            "topic_id": topicID as Any? ?? NSNull(),
            "text": text.isEmpty ? NSNull() : text as Any,
            "attachments": [Any](),
        ]
        if destination == .tunnel { fields["tunnel"] = true }
        try pool.write { db in
            if let topicID {
                if try Bool.fetchOne(db, sql: "SELECT archived_at IS NOT NULL OR deleted_at IS NOT NULL FROM topics WHERE id = ?", arguments: [topicID]) == true { throw ItemActionError.topicUnavailable }
            }
            guard Set(attachmentIDs).count == attachmentIDs.count else { throw AttachmentError("Choose each attachment once") }
            let attachments = try attachmentIDs.map { id -> [String: Any] in
                guard let row = try Row.fetchOne(db, sql: "SELECT s.*, c.path FROM staged_files s JOIN cached_files c ON c.attachment_id = s.id AND c.kind = 'file' WHERE s.id = ?", arguments: [id]),
                      FileManager.default.fileExists(atPath: directory.appending(path: row["path"] as String).path) else { throw AttachmentError("An attachment is no longer available") }
                return ["id": id, "filename": row["filename"] as String, "mime_type": row["mime_type"] as String, "size_bytes": row["size_bytes"] as Int64]
            }
            fields["attachments"] = attachments
            let op = try JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes])
            try db.execute(
                sql: "INSERT INTO items (id, topic_id, text, capture_time, in_tunnel) VALUES (?, ?, ?, ?, ?)",
                arguments: [itemID, topicID, text.isEmpty ? nil : text, nowUs, destination == .tunnel])
            for attachment in attachments {
                try db.execute(sql: "INSERT INTO attachments(id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?, ?, ?, ?, ?, 0, 0)", arguments: [attachment["id"] as! String, itemID, attachment["filename"] as! String, attachment["mime_type"] as! String, attachment["size_bytes"] as! Int64])
                try db.execute(sql: "DELETE FROM staged_files WHERE id = ?", arguments: [attachment["id"] as! String])
            }
            try db.execute(sql: "INSERT INTO outbox (op) VALUES (?)", arguments: [String(decoding: op, as: UTF8.self)])
        }
        return itemID
    }

    public func discard(itemID: String) throws {
        try pool.write { db in
            let refused = try Bool.fetchOne(db, sql: "SELECT sync_error IS NOT NULL FROM items WHERE id = ?", arguments: [itemID])
            guard refused == true else { throw CaptureError.notRefused }
            try db.execute(sql: "DELETE FROM outbox WHERE json_extract(op, '$.item_id') = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [itemID])
        }
    }
}
