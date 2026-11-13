import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct TopicTrashTests {
    @Test @MainActor func topicCountIncludesUnloadedItemsAndExcludesTrash() throws {
        let store = try tempStore().store
        let topic = try store.createTopic(name: "Library", nowUs: 1)
        let model = FeedModel(store: store, place: .topic(topic))
        #expect(model.topicCount == 0)
        for n in 0..<105 {
            _ = try store.capture(text: "Item \(n)", to: .topic(topic), nowUs: Int64(n + 2))
        }
        let trashed = try store.capture(text: "trashed", to: .topic(topic), nowUs: 200)
        try store.trash(itemID: trashed, nowUs: 201)
        model.reload()
        #expect(model.items.count == 100)
        #expect(model.topicCount == 105)
        model.loadOlder()
        #expect(model.items.count == 105)
        #expect(model.topicCount == 105)
    }

    @Test func topicLifecycleAndCaptureGate() throws {
        let store = try tempStore().store
        let id = try store.createTopic(name: " Mosaic ", nowUs: 1)
        #expect(try store.places().topics.first?.name == "Mosaic")
        #expect(throws: (any Error).self) { try store.createTopic(name: "mosaic", nowUs: 2) }
        try store.renameTopic(id, name: "Library", nowUs: 3)
        try store.setTopicArchived(id, archived: true, nowUs: 4)
        #expect(try store.places().topics.isEmpty)
        #expect(try store.archivedTopics().first?.name == "Library")
        #expect(throws: ItemActionError.topicUnavailable) { try store.capture(text: "x", to: .topic(id), nowUs: 5) }
        try store.setTopicArchived(id, archived: false, nowUs: 6)
        #expect(try store.places().topics.count == 1)
    }

    @Test func deleteTopicKeepsOnlySelectedItemsAndRestoreUsesInbox() throws {
        let store = try tempStore().store
        let topic = try store.createTopic(name: "Mosaic", nowUs: 1)
        let keep = try store.capture(text: "keep", to: .topic(topic), nowUs: 2)
        let trash = try store.capture(text: "trash", to: .topic(topic), nowUs: 3)
        try store.deleteTopic(topic, keeping: .only([keep]), nowUs: 4)
        #expect(try store.items(in: .inbox, before: nil, limit: 10).map(\.id) == [keep])
        #expect(try store.items(in: .trash, before: nil, limit: 10).map(\.id) == [trash])
        try store.restore(itemID: trash, nowUs: 5)
        #expect(try store.items(in: .inbox, before: nil, limit: 10).count == 2)
    }

    @Test func attachmentEditAppliesDeltasAndEmptyEditCanBeUndone() throws {
        let (store, file) = try tempStore()
        let source = file.deletingLastPathComponent().appending(path: "sample.txt")
        try Data("hello".utf8).write(to: source)
        let a = try store.stageFile(at: source)
        let id = try store.capture(text: "original", attachmentIDs: [a.id], to: .inbox, nowUs: 1)
        let b = try store.stageFile(at: source)
        #expect(try !store.editItem(itemID: id, text: "edited", baseRev: 0, adding: [b.id], removing: [a.id], nowUs: 2))
        #expect(try store.items(in: .all, before: nil, limit: 10).first?.attachments.map(\.id) == [b.id])
        #expect(try store.editItem(itemID: id, text: "", baseRev: 0, adding: [], removing: [b.id], nowUs: 3))
        try store.restore(itemID: id, nowUs: 4)
        #expect(try store.items(in: .all, before: nil, limit: 10).first?.text == "edited")
    }
}

extension TopicTrashTests {
    @Test func trashExcludesExpiredAndEmptyItems() throws {
        let store = try tempStore().store
        let expired = try store.capture(text: "expired", to: .inbox, nowUs: 1)
        let empty = try store.capture(text: "empty", to: .inbox, nowUs: 2)
        let waiting = try store.capture(text: "waiting", to: .inbox, nowUs: 3)
        for id in [expired,empty,waiting] { try store.trash(itemID: id, nowUs: 4) }
        try store.pool.write { db in
            try db.execute(sql: "UPDATE items SET purge_at = 1 WHERE id = ?", arguments: [expired])
            try db.execute(sql: "UPDATE items SET text = NULL WHERE id = ?", arguments: [empty])
        }
        #expect(try store.items(in: .trash, before: nil, limit: 10).map(\.id) == [waiting])
    }

    @Test func addedAttachmentWaitsForMetadataBeforeUpload() throws {
        let (store,file) = try tempStore()
        let source = file.deletingLastPathComponent().appending(path: "new.txt")
        try Data("new".utf8).write(to: source)
        let id = try store.capture(text: "original", to: .inbox, nowUs: 1)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        let staged = try store.stageFile(at: source)
        _ = try store.editItem(itemID: id, text: "original", baseRev: 0, adding: [staged.id], removing: [], nowUs: 2)
        #expect(try store.pendingUploads().isEmpty)
    }

    @Test func attachmentEditsAndTopicChangesSurviveAnOlderPull() throws {
        let (store,file) = try tempStore()
        try store.pool.write { try $0.execute(sql: "UPDATE device SET server_url = 'https://notes.example.com'") }
        let topic = try store.createTopic(name: "Before", nowUs: 1)
        let id = try store.capture(text: "original", to: .topic(topic), nowUs: 2)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        let source = file.deletingLastPathComponent().appending(path: "new.txt")
        try Data("new".utf8).write(to: source)
        let staged = try store.stageFile(at: source)
        _ = try store.editItem(itemID: id, text: "edited", baseRev: 0, adding: [staged.id], removing: [], nowUs: 3)
        try store.renameTopic(topic, name: "After", nowUs: 4)
        let json = """
        {"items":[{"id":"\(id)","topic_id":"\(topic)","text":"original","capture_time":"2025-10-09T08:53:20Z","deleted_at":null,"purge_at":null,"text_rev":0,"tunnel":false,"attachments":[]}],"topics":[{"id":"\(topic)","name":"Before","archived_at":null,"deleted_at":null}],"tombstones":[],"cursor":1,"has_more":false,"settings":{"trash_after_copy":false}}
        """
        _ = try store.applyPull(JSONDecoder().decode(PullPage.self, from: Data(json.utf8)), serverURL: "https://notes.example.com")
        let item = try #require(store.items(in: .all, before: nil, limit: 10).first)
        #expect(item.text == "edited")
        #expect(item.attachments.map(\.id) == [staged.id])
        #expect(try store.places().topics.first?.name == "After")
        #expect(try store.localFile(staged.id) != nil)
    }
}

extension TopicTrashTests {
    @Test func topicAndAttachmentChangesReachAnotherDeviceThroughRealServer() async throws {
        let server = try TestServer()
        try await server.start()
        let (a,file) = try tempStore()
        let b = try tempStore().store
        let secrets = SecretStore.memory()
        try a.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        try b.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        var notices: [SyncNotice] = []
        let time: Int64 = 1_760_000_000_000_000
        let topic = try a.createTopic(name: "Mosaic", nowUs: time)
        let id = try a.capture(text: "original", to: .topic(topic), nowUs: time + 1)
        _ = try await cycle(store: a, secrets: secrets, http: .live, queued: &notices)
        let source = file.deletingLastPathComponent().appending(path: "new.txt")
        try Data("new".utf8).write(to: source)
        let staged = try a.stageFile(at: source)
        _ = try a.editItem(itemID: id, text: "edited", baseRev: 0, adding: [staged.id], removing: [], nowUs: time + 2)
        try a.renameTopic(topic, name: "Library", nowUs: time + 3)
        try a.setTopicArchived(topic, archived: true, nowUs: time + 4)
        _ = try await cycle(store: a, secrets: secrets, http: .live, queued: &notices)
        _ = try await cycle(store: b, secrets: secrets, http: .live, queued: &notices)
        #expect(try b.archivedTopics().first?.name == "Library")
        let item = try #require(b.items(in: .all, before: nil, limit: 10).first)
        #expect(item.text == "edited")
        #expect(item.attachments.map(\.id) == [staged.id])
        try a.deleteTopic(topic, keeping: .none, nowUs: time + 5)
        _ = try await cycle(store: a, secrets: secrets, http: .live, queued: &notices)
        _ = try await cycle(store: b, secrets: secrets, http: .live, queued: &notices)
        #expect(try b.items(in: .trash, before: nil, limit: 10).first?.purgeAtUs != nil)
        try b.restore(itemID: id, nowUs: time + 6)
        _ = try await cycle(store: b, secrets: secrets, http: .live, queued: &notices)
        #expect(try b.items(in: .inbox, before: nil, limit: 10).first?.id == id)
        #expect(notices.isEmpty)
    }
}

extension TopicTrashTests {
    @Test func conflictingOfflineTopicCreationReportsServerRename() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try tempStore().store
        let b = try tempStore().store
        let secrets = SecretStore.memory()
        for store in [a,b] { try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets) }
        let time: Int64 = 1_760_000_000_000_000
        _ = try a.createTopic(name: "Mosaic", nowUs: time)
        _ = try b.createTopic(name: "Mosaic", nowUs: time + 1)
        var notices: [SyncNotice] = []
        _ = try await cycle(store: a, secrets: secrets, http: .live, queued: &notices)
        _ = try await cycle(store: b, secrets: secrets, http: .live, queued: &notices)
        #expect(try b.places().topics.map(\.name).sorted() == ["Mosaic", "Mosaic (1)"])
        #expect(!notices.isEmpty)
    }
}

extension TopicTrashTests {
    @Test func trashGroupsByServerDeadlineInsteadOfCaptureTime() throws {
        let store = try tempStore().store
        let now = Time.nowUs()
        let day: Int64 = 86_400_000_000
        let a = try store.capture(text: "a", to: .inbox, nowUs: 1)
        let b = try store.capture(text: "b", to: .inbox, nowUs: 2)
        let c = try store.capture(text: "c", to: .inbox, nowUs: 3)
        for id in [a,b,c] { try store.trash(itemID: id, nowUs: now) }
        try store.pool.write { db in
            try db.execute(sql: "UPDATE items SET purge_at = ? WHERE id IN (?,?)", arguments: [now + 20 * day,a,c])
            try db.execute(sql: "UPDATE items SET purge_at = ? WHERE id = ?", arguments: [now + day,b])
        }
        let groups = TrashGroup.group(try store.items(in: .trash, before: nil, limit: 10), nowUs: now)
        #expect(groups.map(\.daysRemaining) == [1,20])
        #expect(groups[1].items.map(\.id) == [c,a])
    }
}

extension TopicTrashTests {
    @Test func trashPagesInDeadlineOrderWithoutSkippingEqualDeadlines() throws {
        let store = try tempStore().store
        let now = Time.nowUs()
        let a = try store.capture(text: "a", to: .inbox, nowUs: 1)
        let b = try store.capture(text: "b", to: .inbox, nowUs: 2)
        let c = try store.capture(text: "c", to: .inbox, nowUs: 3)
        for id in [a,b,c] { try store.trash(itemID: id, nowUs: now) }
        try store.pool.write { db in
            try db.execute(sql: "UPDATE items SET purge_at = ? WHERE id IN (?,?)", arguments: [now + 86_400_000_000,a,b])
            try db.execute(sql: "UPDATE items SET purge_at = ? WHERE id = ?", arguments: [now + 20 * 86_400_000_000,c])
        }
        let first = try store.items(in: .trash, before: nil, limit: 1)
        #expect(first.map(\.id) == [b])
        let second = try store.items(in: .trash, before: first.first?.cursor, limit: 1)
        #expect(second.map(\.id) == [a])
        #expect(try store.items(in: .trash, before: second.first?.cursor, limit: 1).map(\.id) == [c])
    }
}
