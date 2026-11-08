import Foundation
import GRDB

public enum DraftPlace: Hashable, Sendable {
    case home, inbox, tunnel, topic(String)

    public var key: String {
        switch self {
        case .home: "home"
        case .inbox: "inbox"
        case .tunnel: "tunnel"
        case .topic(let id): "topic:" + id
        }
    }
}

public struct Draft: Equatable, Sendable {
    public var text: String
    public var homeTopicID: String?

    public init(text: String, homeTopicID: String? = nil) {
        self.text = text
        self.homeTopicID = homeTopicID
    }
}

extension Store {
    public func drafts() throws -> [DraftPlace: Draft] {
        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM drafts WHERE place LIKE 'topic:_%'
                AND NOT EXISTS (SELECT 1 FROM topics WHERE id = substr(drafts.place, 7) AND deleted_at IS NULL)
                """)
            let rows = try Row.fetchAll(db, sql: """
                SELECT place, text,
                    (SELECT id FROM topics WHERE id = drafts.home_topic_id AND deleted_at IS NULL AND archived_at IS NULL) AS home_topic_id
                FROM drafts
                """)
            var result: [DraftPlace: Draft] = [:]
            for row in rows {
                let key: String = row["place"]
                let place: DraftPlace
                switch key {
                case "home": place = .home
                case "inbox": place = .inbox
                case "tunnel": place = .tunnel
                default: place = .topic(String(key.dropFirst(6)))
                }
                result[place] = Draft(text: row["text"], homeTopicID: row["home_topic_id"])
            }
            return result
        }
    }

    public func saveDraft(_ place: DraftPlace, text: String, homeTopicID: String? = nil) throws {
        try pool.write { db in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try db.execute(sql: "DELETE FROM drafts WHERE place = ?", arguments: [place.key])
            } else {
                try db.execute(sql: """
                    INSERT INTO drafts (place, text, home_topic_id) VALUES (?, ?, ?)
                    ON CONFLICT (place) DO UPDATE SET text = excluded.text, home_topic_id = excluded.home_topic_id
                    """, arguments: [place.key, text, place == .home ? homeTopicID : nil])
            }
        }
    }
}
