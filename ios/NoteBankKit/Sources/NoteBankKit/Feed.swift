import Foundation
import GRDB

public enum Place: Hashable, Codable, Sendable {
    case all, inbox, tunnel, topic(String)
}

public struct FeedCursor: Hashable, Sendable {
    public let captureTimeUs: Int64
    public let id: String

    public init(captureTimeUs: Int64, id: String) {
        self.captureTimeUs = captureTimeUs
        self.id = id
    }
}

public struct FeedItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String?
    public let captureTimeUs: Int64
    public let topicID: String?
    public let topicName: String?
    public let pending: Bool
    public let syncError: String?
    public let attachmentNames: [String]

    public var cursor: FeedCursor { FeedCursor(captureTimeUs: captureTimeUs, id: id) }
    public var label: String { NoteBankKit.label(text: text, firstFilename: attachmentNames.first) }
}

public struct TopicPlace: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let count: Int
}

public struct Places: Equatable, Sendable {
    public let allCount: Int
    public let inboxCount: Int
    public let tunnelCount: Int
    public let topics: [TopicPlace]
}

extension Store {
    public func items(in place: Place, before cursor: FeedCursor?, limit: Int) throws -> [FeedItem] {
        try feed(place, after: cursor.map { ("(items.capture_time, items.id) < (?, ?)", [$0.captureTimeUs, $0.id]) }, limit: limit)
    }

    public func items(in place: Place, from cursor: FeedCursor) throws -> [FeedItem] {
        try feed(place, after: ("(items.capture_time, items.id) >= (?, ?)", [cursor.captureTimeUs, cursor.id]), limit: -1)
    }

    private func feed(_ place: Place, after cursor: (sql: String, arguments: [any DatabaseValueConvertible])?, limit: Int) throws -> [FeedItem] {
        var conditions = ["items.deleted_at IS NULL"]
        var arguments: [any DatabaseValueConvertible] = []
        switch place {
        case .all: break
        case .inbox: conditions.append("items.topic_id IS NULL AND items.in_tunnel = 0")
        case .tunnel: conditions.append("items.in_tunnel = 1")
        case .topic(let id):
            conditions.append("items.topic_id = ?")
            arguments.append(id)
        }
        if let cursor {
            conditions.append(cursor.sql)
            arguments += cursor.arguments
        }
        arguments.append(limit)

        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT items.id, items.text, items.capture_time, items.topic_id, topics.name AS topic_name, items.sync_error,
                           items.sync_error IS NULL AND EXISTS (SELECT 1 FROM outbox WHERE json_extract(op, '$.item_id') = items.id) AS pending
                    FROM items LEFT JOIN topics ON topics.id = items.topic_id
                    WHERE \(conditions.joined(separator: " AND "))
                    ORDER BY items.capture_time DESC, items.id DESC
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments))
            var names: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT item_id, filename FROM attachments WHERE item_id IN (SELECT value FROM json_each(?)) ORDER BY rowid",
                arguments: [String(decoding: try JSONEncoder().encode(rows.map { $0["id"] as String }), as: UTF8.self)])
            {
                names[row["item_id"], default: []].append(row["filename"])
            }
            return rows.map { row in
                FeedItem(
                    id: row["id"], text: row["text"], captureTimeUs: row["capture_time"], topicID: row["topic_id"],
                    topicName: row["topic_name"], pending: row["pending"], syncError: row["sync_error"],
                    attachmentNames: names[row["id"]] ?? [])
            }
        }
    }

    public func places() throws -> Places {
        try pool.read { db in
            let topics = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, (SELECT count(*) FROM items WHERE topic_id = topics.id AND deleted_at IS NULL) AS count
                    FROM topics WHERE deleted_at IS NULL AND archived_at IS NULL
                    """
            ).map { TopicPlace(id: $0["id"], name: $0["name"], count: $0["count"]) }
            return Places(
                allCount: try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE deleted_at IS NULL")!,
                inboxCount: try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE deleted_at IS NULL AND topic_id IS NULL AND in_tunnel = 0")!,
                tunnelCount: try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE deleted_at IS NULL AND in_tunnel = 1")!,
                topics: topics.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }
}
