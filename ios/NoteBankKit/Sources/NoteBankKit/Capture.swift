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

    public func capture(text: String, to destination: Destination, nowUs: Int64) throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= Store.maxItemTextBytes else { throw CaptureError.tooLong }
        guard !text.utf8.contains(0) else { throw CaptureError.unsavableCharacter }
        guard !text.isEmpty else { throw CaptureError.blank }

        let itemID = UUID().uuidString.lowercased()
        var topicID: String?
        if case .topic(let id) = destination { topicID = id }
        var fields: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "type": "CaptureItem",
            "at": Time.rfc3339(nowUs),
            "item_id": itemID,
            "topic_id": topicID as Any? ?? NSNull(),
            "text": text,
            "attachments": [Any](),
        ]
        if destination == .tunnel { fields["tunnel"] = true }
        let op = try JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes])
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO items (id, topic_id, text, capture_time, in_tunnel) VALUES (?, ?, ?, ?, ?)",
                arguments: [itemID, topicID, text, nowUs, destination == .tunnel])
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
