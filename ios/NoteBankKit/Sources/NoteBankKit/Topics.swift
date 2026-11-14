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
            try db.execute(sql: "INSERT INTO topics(id,name,activity_at) VALUES (?,?,?)", arguments: [id,name,nowUs])
            try queue(db, "CreateTopic", nowUs: nowUs, ["topic_id":id,"name":name])
            return id
        }
    }

    private func pickerMatch(_ db: Database, _ name: String) throws -> (name: String, openID: String?) {
        let name = try validTopicName(name)
        let same = try Row.fetchAll(db, sql: "SELECT id, name FROM topics WHERE deleted_at IS NULL")
            .filter { ($0["name"] as String).lowercased() == name.lowercased() }
        if let open = same.first { return (name, open["id"]) }
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
            try db.execute(sql: "INSERT INTO topics(id,name,activity_at) VALUES (?,?,?)", arguments: [id,name,nowUs])
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

    public func topic(_ id: String) throws -> (name: String, count: Int)? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT name, (SELECT count(*) FROM items WHERE topic_id = topics.id AND deleted_at IS NULL) AS count FROM topics WHERE id = ? AND deleted_at IS NULL", arguments: [id]).map { ($0["name"], $0["count"]) }
        }
    }

    @discardableResult
    public func deleteTopic(_ id: String, keeping: TopicKeep, nowUs: Int64) throws -> String {
        try pool.write { db in
            guard let name = try String.fetchOne(db, sql: "SELECT name FROM topics WHERE id = ? AND deleted_at IS NULL", arguments: [id]) else { throw ItemActionError.topicUnavailable }
            let ids = try String.fetchAll(db, sql: "SELECT id FROM items WHERE topic_id = ? AND deleted_at IS NULL", arguments: [id])
            let trash = ids.filter { item in
                switch keeping { case .all: false; case .none: true; case .only(let kept): !kept.contains(item) }
            }
            try applyTopicDeletion(db, id: id, trash: trash, nowUs: nowUs)
            try queue(db, "DeleteTopic", nowUs: nowUs, ["topic_id":id,"trash":trash])
            let kept = ids.count - trash.count
            let count = { (n: Int) in "\(n) \(n == 1 ? "Item" : "Items")" }
            let moved: String
            if ids.isEmpty { moved = "" }
            else { switch keeping {
            case .all: moved = " \(count(kept)) moved to the Inbox."
            case .none: moved = " \(count(trash.count)) moved to Trash."
            case .only: moved = " \(count(kept)) moved to the Inbox, \(trash.count) to Trash."
            } }
            return "Deleted \"\(name)\".\(moved)"
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
