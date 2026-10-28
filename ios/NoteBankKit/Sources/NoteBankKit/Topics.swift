import Foundation
import GRDB

public enum TopicKeep { case all, none, only(Set<String>) }

extension Store {
    private func checkedTopicName(_ db: Database, _ name: String, excluding id: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200, !name.utf8.contains(0) else {
            throw AttachmentError("Enter a Topic name of 1–200 bytes without null characters")
        }
        let names = try String.fetchAll(db, sql: "SELECT name FROM topics WHERE deleted_at IS NULL AND id <> ?", arguments: [id])
        guard !names.contains(where: { $0.lowercased() == name.lowercased() }) else { throw AttachmentError("A Topic with that name already exists") }
        return name
    }

    public func createTopic(name: String, nowUs: Int64) throws -> String {
        try pool.write { db in
            let id = UUID().uuidString.lowercased()
            let name = try checkedTopicName(db, name, excluding: id)
            try db.execute(sql: "INSERT INTO topics(id,name) VALUES (?,?)", arguments: [id,name])
            try queue(db, "CreateTopic", nowUs: nowUs, ["topic_id":id,"name":name])
            return id
        }
    }

    public func renameTopic(_ id: String, name: String, nowUs: Int64) throws {
        try pool.write { db in
            guard let old = try String.fetchOne(db, sql: "SELECT name FROM topics WHERE id = ? AND deleted_at IS NULL", arguments: [id]) else { throw ItemActionError.topicUnavailable }
            let name = try checkedTopicName(db, name, excluding: id)
            guard old != name else { return }
            try db.execute(sql: "UPDATE topics SET name = ? WHERE id = ?", arguments: [name,id])
            try queue(db, "RenameTopic", nowUs: nowUs, ["topic_id":id,"name":name])
        }
    }

    public func setTopicArchived(_ id: String, archived: Bool, nowUs: Int64) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT deleted_at IS NULL FROM topics WHERE id = ?", arguments: [id]) == true else { throw ItemActionError.topicUnavailable }
            try db.execute(sql: "UPDATE topics SET archived_at = ? WHERE id = ?", arguments: [archived ? nowUs : nil,id])
            try queue(db, archived ? "ArchiveTopic" : "UnarchiveTopic", nowUs: nowUs, ["topic_id":id])
        }
    }

    public func archivedTopics() throws -> [TopicPlace] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id,name,(SELECT count(*) FROM items WHERE topic_id = topics.id AND deleted_at IS NULL) AS count FROM topics WHERE deleted_at IS NULL AND archived_at IS NOT NULL ORDER BY name COLLATE NOCASE,id")
                .map { TopicPlace(id: $0["id"], name: $0["name"], count: $0["count"]) }
        }
    }

    public func topic(_ id: String) throws -> (name: String, archived: Bool)? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT name, archived_at IS NOT NULL AS archived FROM topics WHERE id = ? AND deleted_at IS NULL", arguments: [id]).map { ($0["name"], $0["archived"]) }
        }
    }

    public func deleteTopic(_ id: String, keeping: TopicKeep, nowUs: Int64) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT deleted_at IS NULL FROM topics WHERE id = ?", arguments: [id]) == true else { throw ItemActionError.topicUnavailable }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM items WHERE topic_id = ? AND deleted_at IS NULL", arguments: [id])
            let trash = ids.filter { item in
                switch keeping { case .all: false; case .none: true; case .only(let kept): !kept.contains(item) }
            }
            try applyTopicDeletion(db, id: id, trash: trash, nowUs: nowUs)
            try queue(db, "DeleteTopic", nowUs: nowUs, ["topic_id":id,"trash":trash])
        }
    }

    func applyTopicDeletion(_ db: Database, id: String, trash: [String], nowUs: Int64) throws {
        for item in trash {
            try db.execute(sql: "UPDATE items SET deleted_at = ?, purge_at = NULL WHERE id = ? AND topic_id = ? AND deleted_at IS NULL", arguments: [nowUs,item,id])
        }
        try db.execute(sql: "UPDATE items SET topic_id = NULL WHERE topic_id = ?", arguments: [id])
        try db.execute(sql: "UPDATE topics SET deleted_at = ? WHERE id = ?", arguments: [nowUs,id])
    }
}
