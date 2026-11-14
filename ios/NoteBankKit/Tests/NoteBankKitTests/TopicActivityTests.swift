import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct TopicActivityTests {
    private func activity(_ store: Store, _ id: String) throws -> Int64 {
        try store.quickPlace(.topic(id))!.lastUsedUs ?? -1
    }

    @Test func creationAndCaptureRankByOperationTime() throws {
        let store = try tempStore().store
        let old = try store.createTopic(name: "Old", nowUs: 10)
        let new = try store.pickerTopic(named: "New", nowUs: 20)
        #expect(try activity(store, old) == 10)
        #expect(try activity(store, new) == 20)
        #expect(try store.places().topics.map(\.id) == [new, old])
        _ = try store.capture(text: "capture", to: .topic(old), nowUs: 30)
        #expect(try store.places().topics.map(\.id) == [old, new])
        _ = try store.capture(text: "older", to: .topic(old), nowUs: 15)
        #expect(try activity(store, old) == 30)
        #expect(try store.pickerTopic(named: "Old", nowUs: 100) == old)
        #expect(try activity(store, old) == 30)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(usedLabel(lastUsedUs: try activity(store, new), nowUs: 20, calendar: calendar) == "Used today")
    }

    @Test func onlyMoveIntoRaisesAndOtherActionsRetainActivity() throws {
        let store = try tempStore().store
        let a = try store.createTopic(name: "Alpha", nowUs: 10)
        let b = try store.createTopic(name: "Beta", nowUs: 20)
        let item = try store.capture(text: "one", to: .topic(a), nowUs: 30)
        try store.move(itemID: item, to: .topic(b), nowUs: 40)
        #expect(try activity(store, a) == 30)
        #expect(try activity(store, b) == 40)
        try store.move(itemID: item, to: .topic(b), nowUs: 25)
        _ = try store.editText(itemID: item, text: "edited", baseRev: 0, nowUs: 50)
        try store.trash(itemID: item, nowUs: 60)
        try store.restore(itemID: item, nowUs: 70)
        try store.renameTopic(b, name: "Renamed", nowUs: 80)
        try store.move(itemID: item, to: .inbox, nowUs: 90)
        #expect(try activity(store, b) == 40)
        #expect(try store.places().topics.map(\.id) == [b, a])
        #expect(throws: ItemActionError.self) { try store.move(itemID: "missing", to: .topic(a), nowUs: 100) }
        #expect(try activity(store, a) == 30)
    }

    @Test func draftSendAndAttachmentEditsUseCaptureActivity() throws {
        let store = try tempStore().store
        let id = try store.createTopic(name: "Draft", nowUs: 10)
        try store.saveDraft(.topic(id), text: "draft")
        #expect(try activity(store, id) == 10)
        let file = store.directory.appending(path: "source.txt")
        try Data("attachment".utf8).write(to: file)
        let attachment = try store.stageFile(at: file)
        let item = try store.capture(text: "draft", attachmentIDs: [attachment.id], to: .topic(id), draft: .topic(id), nowUs: 20)
        #expect(try activity(store, id) == 20)
        #expect(try store.drafts()[.topic(id)] == nil)
        _ = try store.editItem(itemID: item, text: "edited", baseRev: 0, adding: [], removing: [attachment.id], nowUs: 30)
        #expect(try activity(store, id) == 20)
    }

    @Test func batchTrashRestoreAndTopicDeletionMoveOutKeepActivity() throws {
        let store = try tempStore().store
        let id = try store.createTopic(name: "Batch", nowUs: 10)
        let items = try [20, 30].map { try store.capture(text: "item", to: .topic(id), nowUs: Int64($0)) }
        try store.trash(itemIDs: items, nowUs: 40)
        #expect(try activity(store, id) == 30)
        try store.restore(itemIDs: items, nowUs: 50)
        #expect(try activity(store, id) == 30)
        try store.deleteTopic(id, keeping: .all, nowUs: 60)
        #expect(try store.items(in: .inbox, before: nil, limit: 10).count == 2)
        #expect(try store.pool.read { try Int64.fetchOne($0, sql: "SELECT activity_at FROM topics WHERE id = ?", arguments: [id]) } == 30)
    }

    private func pull(_ store: Store, topics: [[String: Any]], items: [[String: Any]] = []) throws {
        let page = try JSONDecoder().decode(PullPage.self, from: JSONSerialization.data(withJSONObject: [
            "topics": topics, "items": items, "settings": [:], "tombstones": [], "cursor": 1, "has_more": false
        ]))
        try store.pool.write { try $0.execute(sql: "UPDATE device SET server_url = 'http://127.0.0.1:9'") }
        _ = try store.applyPull(page, serverURL: "http://127.0.0.1:9")
    }

    @Test func pullCompatibilityAndAuthoritativeOverwrite() throws {
        let store = try tempStore().store
        let id = try store.createTopic(name: "Local", nowUs: 300)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        try pull(store, topics: [["id": id, "name": "Old Server"], ["id": "empty", "name": "Empty"]])
        #expect(try activity(store, id) == 300)
        #expect(try activity(store, "empty") == 0)
        try pull(store, topics: [["id": id, "name": "New Server", "activity_at": Time.rfc3339(100)]])
        #expect(try activity(store, id) == 100)
        try pull(store, topics: [], items: [["id": "remote", "topic_id": id, "text": "remote", "capture_time": Time.rfc3339(200), "text_rev": 0, "tunnel": false, "attachments": [], "deleted_at": Time.rfc3339(250)]])
        #expect(try activity(store, id) == 200)
    }

    @Test func pendingCreateCaptureAndMoveReRaiseAfterPull() throws {
        for operation in ["create", "capture", "move"] {
            let store = try tempStore().store
            let id = try store.createTopic(name: "Local", nowUs: 100)
            if operation != "create" { try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") } }
            if operation == "capture" { _ = try store.capture(text: "local", to: .topic(id), nowUs: 300) }
            if operation == "move" {
                let item = try store.capture(text: "local", to: .inbox, nowUs: 50)
                try store.move(itemID: item, to: .topic(id), nowUs: 300)
            }
            try pull(store, topics: [["id": id, "name": "Server", "activity_at": Time.rfc3339(10)]])
            #expect(try activity(store, id) == (operation == "create" ? 100 : 300))
            try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
            try pull(store, topics: [["id": id, "name": "Server", "activity_at": Time.rfc3339(10)]])
            #expect(try activity(store, id) == 10)
        }
    }

    @Test func activityMigrationIncludesTrashedItemsAndEmptyTopics() throws {
        let pool = try DatabaseQueue()
        try DatabaseMigrator.noteBank.migrate(pool, upTo: "v9")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO topics (id, name) VALUES ('mixed', 'Mixed'), ('empty', 'Empty'), ('trashed', 'Trashed');
                INSERT INTO items (id, topic_id, text, capture_time, deleted_at) VALUES
                    ('live', 'mixed', 'live', 10, NULL), ('trash', 'mixed', 'trash', 30, 40), ('only', 'trashed', 'trash', 50, 60);
                """)
        }
        try DatabaseMigrator.noteBank.migrate(pool)
        try pool.read { db throws -> Void in
            #expect(try Int64.fetchAll(db, sql: "SELECT activity_at FROM topics ORDER BY id") == [0, 30, 50])
            #expect(throws: DatabaseError.self) { try db.execute(sql: "UPDATE topics SET activity_at = NULL") }
        }
    }
}
