import Darwin
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
    public var attachments: [StagedAttachment]
    public var text: String
    public var homeTopicID: String?

    public init(text: String, homeTopicID: String? = nil, attachments: [StagedAttachment] = []) {
        self.attachments = attachments
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
                    (SELECT id FROM topics WHERE id = drafts.home_topic_id AND deleted_at IS NULL) AS home_topic_id
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
                let attachments = try Row.fetchAll(db, sql: "SELECT s.* FROM draft_attachments d JOIN staged_files s ON s.id = d.attachment_id WHERE d.place = ? ORDER BY d.position", arguments: [key]).map { row in
                    StagedAttachment(id: row["id"], filename: row["filename"], mimeType: row["mime_type"], sizeBytes: row["size_bytes"])
                }
                result[place] = Draft(text: row["text"], homeTopicID: row["home_topic_id"], attachments: attachments)
            }
            return result
        }
    }

    public func saveDraft(_ place: DraftPlace, text: String, homeTopicID: String? = nil, attachmentIDs: [String]) throws {
        try pool.write { db in
            try saveDraft(db, place, text: text, homeTopicID: homeTopicID, attachmentIDs: attachmentIDs)
        }
    }

    public func removeDraftAttachment(_ id: String, from place: DraftPlace, text: String, homeTopicID: String? = nil, attachmentIDs: [String]) throws {
        let path = try pool.write { db in
            try Self.requireUnowned(db, id: id, source: place.key)
            try saveDraft(db, place, text: text, homeTopicID: homeTopicID, attachmentIDs: attachmentIDs)
            return try Self.discardStaged(db, id: id)
        }
        if let path { try? FileManager.default.removeItem(at: directory.appending(path: path).deletingLastPathComponent()) }
    }

    private func saveDraft(_ db: Database, _ place: DraftPlace, text: String, homeTopicID: String?, attachmentIDs: [String]) throws {
        for id in attachmentIDs {
            try Self.requireUnowned(db, id: id, source: place.key)
            let owned = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM draft_attachments WHERE attachment_id = ? AND place = ?)", arguments: [id, place.key]) == true
            if !owned {
                guard let path = try String.fetchOne(db, sql: "SELECT c.path FROM staged_files s JOIN cached_files c ON c.attachment_id = s.id AND c.kind = 'file' WHERE s.id = ?", arguments: [id]) else { throw AttachmentError("An attachment is missing; add it again") }
                let handle = try FileHandle(forReadingFrom: directory.appending(path: path))
                defer { try? handle.close() }
                try handle.synchronize()
                for folder in [directory.appending(path: path).deletingLastPathComponent(), directory.appending(path: "files")] {
                    let descriptor = Darwin.open(folder.path, O_RDONLY)
                    guard descriptor >= 0 else { throw AttachmentError("Attachment failed to save") }
                    let result = Darwin.fsync(descriptor)
                    Darwin.close(descriptor)
                    guard result == 0 else { throw AttachmentError("Attachment failed to save") }
                }
            }
        }
        try db.execute(sql: "DELETE FROM draft_attachments WHERE place = ?", arguments: [place.key])
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentIDs.isEmpty {
            try db.execute(sql: "DELETE FROM drafts WHERE place = ?", arguments: [place.key])
        } else {
            try db.execute(sql: "INSERT INTO drafts(place,text,home_topic_id) VALUES (?,?,?) ON CONFLICT(place) DO UPDATE SET text=excluded.text, home_topic_id=excluded.home_topic_id", arguments: [place.key, text, place == .home ? homeTopicID : nil])
            for (position,id) in attachmentIDs.enumerated() {
                try db.execute(sql: "INSERT INTO draft_attachments VALUES (?,?,?)", arguments: [id, place.key, position])
            }
        }
    }

    public func saveDraft(_ place: DraftPlace, text: String, homeTopicID: String? = nil) throws {
        try pool.write { db in
            let owned = try Int.fetchOne(db, sql: "SELECT count(*) FROM draft_attachments WHERE place = ?", arguments: [place.key])!
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && owned == 0 {
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
