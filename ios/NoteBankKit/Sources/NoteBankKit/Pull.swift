import Foundation
import GRDB

struct PullPage: Decodable {
    struct Instant: Decodable {
        let us: Int64

        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let us = Time.micros(rfc3339: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 time"))
            }
            self.us = us
        }
    }

    struct Attachment: Decodable {
        let id: String
        let filename: String
        let mimeType: String
        let sizeBytes: Int64
        let uploaded: Bool
        let hasThumbnail: Bool

        enum CodingKeys: String, CodingKey {
            case id, filename, uploaded
            case mimeType = "mime_type", sizeBytes = "size_bytes", hasThumbnail = "has_thumbnail"
        }
    }

    struct Item: Decodable {
        let id: String
        let topicID: String?
        let text: String?
        let captureTime: Instant
        let deletedAt: Instant?
        let purgeAt: Instant?
        let textRev: Int64
        let tunnel: Bool
        let attachments: [Attachment]

        enum CodingKeys: String, CodingKey {
            case id, text, tunnel, attachments
            case topicID = "topic_id", captureTime = "capture_time", deletedAt = "deleted_at", purgeAt = "purge_at", textRev = "text_rev"
        }
    }

    struct Topic: Decodable {
        let id: String
        let name: String
        let archivedAt: Instant?
        let deletedAt: Instant?

        enum CodingKeys: String, CodingKey {
            case id, name
            case archivedAt = "archived_at", deletedAt = "deleted_at"
        }
    }

    struct Settings: Decodable {
        let trashAfterCopy: Bool?

        enum CodingKeys: String, CodingKey { case trashAfterCopy = "trash_after_copy" }

        init(from decoder: Decoder) throws {
            trashAfterCopy = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .trashAfterCopy)
        }
    }

    let items: [Item]
    let settings: Settings
    let topics: [Topic]
    let tombstones: [String]
    let cursor: Int64
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items, settings, topics, tombstones, cursor
        case hasMore = "has_more"
    }
}

extension Store {
    func applyPull(_ page: PullPage, serverURL: String) throws -> Bool {
        try pool.write { db in
            // A page only means something to the Server it came from.
            guard try Bool.fetchOne(db, sql: "SELECT server_url = ? FROM device", arguments: [serverURL]) == true else { return false }
            for topic in page.topics {
                try db.execute(
                    sql: """
                        INSERT INTO topics (id, name, archived_at, deleted_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT (id) DO UPDATE SET
                            name = excluded.name, archived_at = excluded.archived_at, deleted_at = excluded.deleted_at
                        """,
                    arguments: [topic.id, topic.name, topic.archivedAt?.us, topic.deletedAt?.us])
            }
            for item in page.items {
                try db.execute(
                    sql: """
                        INSERT INTO items (id, topic_id, text, capture_time, deleted_at, purge_at, text_rev, in_tunnel)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT (id) DO UPDATE SET
                            topic_id = excluded.topic_id, text = excluded.text, capture_time = excluded.capture_time,
                            deleted_at = CASE WHEN EXISTS (
                                    SELECT 1 FROM outbox WHERE json_extract(op, '$.item_id') = items.id AND json_extract(op, '$.type') IN ('TrashItem', 'RestoreItem'))
                                THEN items.deleted_at ELSE excluded.deleted_at END,
                            purge_at = CASE WHEN EXISTS (
                                    SELECT 1 FROM outbox WHERE json_extract(op, '$.item_id') = items.id AND json_extract(op, '$.type') IN ('TrashItem', 'RestoreItem'))
                                THEN items.purge_at ELSE excluded.purge_at END,
                            text_rev = excluded.text_rev, in_tunnel = excluded.in_tunnel, sync_error = NULL
                        """,
                    arguments: [item.id, item.topicID, item.text, item.captureTime.us, item.deletedAt?.us, item.purgeAt?.us, item.textRev, item.tunnel])
                // Pull sends the Item's whole live set, so anything missing from it was removed.
                try db.execute(
                    sql: "DELETE FROM attachments WHERE item_id = ? AND id NOT IN (SELECT value FROM json_each(?))",
                    arguments: [item.id, String(decoding: try JSONEncoder().encode(item.attachments.map(\.id)), as: UTF8.self)])
                for a in item.attachments {
                    try db.execute(
                        sql: """
                            INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT (id) DO UPDATE SET
                                item_id = excluded.item_id, filename = excluded.filename, mime_type = excluded.mime_type,
                                size_bytes = excluded.size_bytes, uploaded = excluded.uploaded, has_thumbnail = excluded.has_thumbnail
                            """,
                        arguments: [a.id, item.id, a.filename, a.mimeType, a.sizeBytes, a.uploaded, a.hasThumbnail])
                }
            }
            for id in page.tombstones {
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            }
            try db.execute(
                sql: """
                    UPDATE settings SET trash_after_copy = ?
                    WHERE NOT EXISTS (SELECT 1 FROM outbox WHERE json_extract(op, '$.type') = 'SetTrashAfterCopy')
                    """,
                arguments: [page.settings.trashAfterCopy])
            try db.execute(sql: "UPDATE device SET pull_cursor = ?", arguments: [page.cursor])
            return !(page.items.isEmpty && page.topics.isEmpty && page.tombstones.isEmpty)
        }
    }
}
