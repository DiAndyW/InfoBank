import Foundation
import GRDB

public enum TopicKeep { case all, none, only(Set<String>) }

extension Store {
    private static let builtInTopicNames: Set<String> = ["inbox", "tunnel", "trash", "all items", "anywhere", "new topic"]

    private func validTopicName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw AttachmentError("A Topic name can't contain line breaks, tabs or other control characters")
        }
        if name.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || $0.properties.generalCategory == .format }) {
            throw AttachmentError("Give the Topic a name")
        }
        guard name.utf8.count <= 200 else { throw AttachmentError("That name is too long (200 bytes max)") }
        var base = name
        if base.hasSuffix("…") { base.removeLast() }
        if base.hasSuffix("...") { base.removeLast(3) }
        base = base.trimmingCharacters(in: .whitespaces)
        if Self.builtInTopicNames.contains(base.lowercased()) { throw AttachmentError("“\(base)” is a built-in name. Pick another.") }
        return name
    }

    private func checkedTopicName(_ db: Database, _ name: String, excluding id: String) throws -> String {
        let name = try validTopicName(name)
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

    /// For Topic pickers: an open Topic with this name is reused; an archived one is refused.
    private func pickerMatch(_ db: Database, _ name: String) throws -> (name: String, openID: String?) {
        let name = try validTopicName(name)
        let same = try Row.fetchAll(db, sql: "SELECT id, name, archived_at IS NOT NULL AS archived FROM topics WHERE deleted_at IS NULL")
            .filter { ($0["name"] as String).lowercased() == name.lowercased() }
        if let open = same.first(where: { !($0["archived"] as Bool) }) { return (name, open["id"]) }
        guard same.isEmpty else { throw AttachmentError("An archived Topic has that name. Unarchive it in Places or pick another name.") }
        return (name, nil)
    }

    public func pickerTopicProblem(named name: String) throws -> String? {
        try pool.read { db in
            do {
                _ = try pickerMatch(db, name)
                return nil
            } catch let error as AttachmentError {
                return error.message
            }
        }
    }

    public func pickerTopic(named name: String, nowUs: Int64) throws -> String {
        try pool.write { db in
            let (name, openID) = try pickerMatch(db, name)
            if let openID { return openID }
            let id = UUID().uuidString.lowercased()
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
