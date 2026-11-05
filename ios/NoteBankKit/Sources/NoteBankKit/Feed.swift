import Foundation
import GRDB

public enum Place: Hashable, Codable, Sendable {
    case all, inbox, tunnel, trash, topic(String)
}

public struct FeedCursor: Hashable, Sendable {
    public let captureTimeUs: Int64
    public let id: String

    public let purgeAtUs: Int64?

    public init(captureTimeUs: Int64, id: String, purgeAtUs: Int64? = nil) {
        self.captureTimeUs = captureTimeUs
        self.id = id
        self.purgeAtUs = purgeAtUs
    }
}

public struct FeedItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String?
    public let captureTimeUs: Int64
    public let topicID: String?
    public let topicName: String?
    public let inTunnel: Bool
    public var purgeAtUs: Int64? = nil
    public let editBase: Int64
    public let conflict: TextConflict?
    public let pending: Bool
    public let syncError: String?
    public let attachments: [FeedAttachment]
    public var attachmentNames: [String] { attachments.map(\.filename) }

    public var destination: Destination { inTunnel ? .tunnel : topicID.map(Destination.topic) ?? .inbox }

    public var cursor: FeedCursor { FeedCursor(captureTimeUs: captureTimeUs, id: id, purgeAtUs: purgeAtUs) }
    public var label: String { NoteBankKit.label(text: text, firstFilename: attachmentNames.first) }
}

public struct TopicPlace: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let count: Int

    public init(id: String, name: String, count: Int) { self.id = id; self.name = name; self.count = count }
}

extension TopicPlace {
    public static func browsing(_ topics: [TopicPlace], archived: Bool, expanded: Bool, retaining id: String? = nil) -> [TopicPlace] {
        let sorted = topics.sorted {
            if !archived && !expanded && $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return expanded ? sorted : sorted.enumerated().filter { $0.offset < 10 || $0.element.id == id }.map(\.element)
    }

    public static func matching(_ topics: [TopicPlace], text: String) -> [TopicPlace] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return topics.filter { $0.name.range(of: query, options: .caseInsensitive) != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct Places: Equatable, Sendable {
    public let allCount: Int
    public let inboxCount: Int
    public let tunnelCount: Int
    public let topics: [TopicPlace]
}

extension Store {
    public func items(in place: Place, before cursor: FeedCursor?, limit: Int) throws -> [FeedItem] {
        if place == .trash {
            return try feed(place, after: cursor.map { ("(COALESCE(items.purge_at, 9223372036854775807), -items.capture_time, items.id) > (?, ?, ?)", [$0.purgeAtUs ?? Int64.max, -$0.captureTimeUs, $0.id]) }, limit: limit)
        }
        return try feed(place, after: cursor.map { ("(items.capture_time, items.id) < (?, ?)", [$0.captureTimeUs, $0.id]) }, limit: limit)
    }

    public func items(in place: Place, from cursor: FeedCursor) throws -> [FeedItem] {
        if place == .trash {
            return try feed(place, after: ("(COALESCE(items.purge_at, 9223372036854775807), -items.capture_time, items.id) <= (?, ?, ?)", [cursor.purgeAtUs ?? Int64.max, -cursor.captureTimeUs, cursor.id]), limit: -1)
        }
        return try feed(place, after: ("(items.capture_time, items.id) >= (?, ?)", [cursor.captureTimeUs, cursor.id]), limit: -1)
    }

    func cursor(ofItem id: String, in place: Place) throws -> FeedCursor? {
        try feed(place, after: ("items.id = ?", [id]), limit: 1).first?.cursor
    }

    private func feed(_ place: Place, after cursor: (sql: String, arguments: [any DatabaseValueConvertible])?, limit: Int) throws -> [FeedItem] {
        var conditions = [place == .trash ? "items.deleted_at IS NOT NULL" : "items.deleted_at IS NULL"]
        var arguments: [any DatabaseValueConvertible] = []
        switch place {
        case .all: break
        case .trash:
            conditions.append("(items.purge_at IS NULL OR items.purge_at > ?)")
            conditions.append("(items.text IS NOT NULL OR EXISTS(SELECT 1 FROM attachments WHERE item_id = items.id))")
            arguments.append(Time.nowUs())
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
                    SELECT \(Self.feedColumns)
                    FROM items LEFT JOIN topics ON topics.id = items.topic_id
                    WHERE \(conditions.joined(separator: " AND "))
                    ORDER BY \(place == .trash ? "COALESCE(items.purge_at, 9223372036854775807) ASC, -items.capture_time ASC, items.id ASC" : "items.capture_time DESC, items.id DESC")
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments))
            return try Self.feedItems(db, rows)
        }
    }

    static let feedColumns = """
        items.purge_at, items.id, items.text, items.capture_time, items.topic_id, topics.name AS topic_name, items.sync_error, items.in_tunnel,
        COALESCE((SELECT json_extract(op, '$.base_rev') FROM outbox WHERE json_extract(op, '$.item_id') = items.id
            AND json_extract(op, '$.type') = 'SetText' ORDER BY seq DESC LIMIT 1), items.text_rev) AS edit_base,
        (SELECT text FROM conflicts WHERE item_id = items.id) AS conflict_text,
        (SELECT mine FROM conflicts WHERE item_id = items.id) AS conflict_mine,
        items.sync_error IS NULL AND (EXISTS (SELECT 1 FROM outbox WHERE json_extract(op, '$.item_id') = items.id) OR EXISTS (SELECT 1 FROM attachments WHERE item_id = items.id AND uploaded = 0)) AS pending
        """

    static func feedItems(_ db: Database, _ rows: [Row]) throws -> [FeedItem] {
        var attachments: [String: [FeedAttachment]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT a.*, NULLIF(u.error, '') AS upload_error FROM attachments a LEFT JOIN attachment_uploads u ON u.attachment_id = a.id WHERE a.item_id IN (SELECT value FROM json_each(?)) ORDER BY a.rowid",
            arguments: [String(decoding: try JSONEncoder().encode(rows.map { $0["id"] as String }), as: UTF8.self)])
        {
            attachments[row["item_id"], default: []].append(Self.feedAttachment(row))
        }
        return rows.map { row in
            FeedItem(
                id: row["id"], text: row["text"], captureTimeUs: row["capture_time"], topicID: row["topic_id"],
                topicName: row["topic_name"], inTunnel: row["in_tunnel"], purgeAtUs: row["purge_at"], editBase: row["edit_base"],
                conflict: (row["conflict_mine"] as Bool?).map { TextConflict(text: row["conflict_text"], mine: $0) }, pending: row["pending"], syncError: row["sync_error"],
                attachments: attachments[row["id"]] ?? [])
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
