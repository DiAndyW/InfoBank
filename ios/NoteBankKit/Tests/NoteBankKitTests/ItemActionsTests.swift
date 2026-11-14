import Foundation
import GRDB
import Testing
@testable import NoteBankKit

private let actionTime: Int64 = 1_760_000_000_000_000

struct ItemActionsTests {
    private func ops(_ store: Store) throws -> [[String: Any]] {
        try store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT op FROM outbox ORDER BY seq").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }
    }

    @Test func editingPreservesAttachmentsAndRevisionAcrossRepeatedOfflineEdits() throws {
        let store = try tempStore().store
        let id = try store.capture(text: "original", to: .inbox, nowUs: actionTime)
        try store.pool.write { db in
            try db.execute(sql: "UPDATE items SET text_rev = 7 WHERE id = ?", arguments: [id])
            try db.execute(sql: "INSERT INTO attachments VALUES ('a', ?, 'file.pdf', 'application/pdf', 1, 1, 0)", arguments: [id])
            try db.execute(sql: "DELETE FROM outbox")
        }
        #expect(try !store.editText(itemID: id, text: "edited", baseRev: 7, nowUs: actionTime + 1))
        #expect(try !store.editText(itemID: id, text: "again", baseRev: 7, nowUs: actionTime + 2))
        let item = try #require(store.items(in: .all, before: nil, limit: 10).first)
        #expect(item.text == "again")
        #expect(item.attachmentNames == ["file.pdf"])
        #expect(item.editBase == 7)
        #expect(try ops(store).last?["base_rev"] as? Int == 7)
        #expect(try !store.editText(itemID: id, text: "", baseRev: 7, nowUs: actionTime + 3))
        #expect(try store.items(in: .all, before: nil, limit: 10).first?.text == nil)
    }

    @Test func emptyTextOnlyEditTrashesWithoutErasingContentAndUndoRestoresIt() throws {
        let store = try tempStore().store
        let id = try store.capture(text: "keep for undo", to: .tunnel, nowUs: actionTime)
        #expect(try store.editText(itemID: id, text: "  ", baseRev: 0, nowUs: actionTime + 1))
        #expect(try store.items(in: .all, before: nil, limit: 10).isEmpty)
        try store.restore(itemID: id, nowUs: actionTime + 2)
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).first?.text == "keep for undo")
        #expect(try ops(store).map { $0["type"] as! String } == ["CaptureItem", "TrashItem", "RestoreItem"])
    }

    @Test func movesHaveCompleteDestinationsAndRejectUnavailableTopicsAtomically() throws {
        let store = try tempStore().store
        let id = try store.capture(text: "move", to: .inbox, nowUs: actionTime)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO topics(id,name) VALUES ('g','Gym')")
            try db.execute(sql: "DELETE FROM outbox")
        }
        try store.move(itemID: id, to: .tunnel, nowUs: actionTime + 1)
        #expect(try store.places().tunnelCount == 1)
        #expect(try ops(store).last?["tunnel"] as? Bool == true)
        try store.move(itemID: id, to: .topic("g"), nowUs: actionTime + 2)
        #expect(try store.places().tunnelCount == 0)
        #expect(try store.items(in: .topic("g"), before: nil, limit: 10).first?.topicID == "g")
        try store.pool.write { try $0.execute(sql: "UPDATE topics SET deleted_at = 1") }
        let before = try ops(store).count
        #expect(throws: ItemActionError.topicUnavailable) { try store.move(itemID: id, to: .topic("g"), nowUs: actionTime + 3) }
        #expect(throws: ItemActionError.topicUnavailable) { try store.move(itemID: id, to: .topic("missing"), nowUs: actionTime + 3) }
        #expect(try ops(store).count == before)
        try store.move(itemID: id, to: .inbox, nowUs: actionTime + 4)
        #expect(try store.places().inboxCount == 1)
    }

    @Test func aFailedWriteRollsBackAndMissingItemsDoNotQueueEdits() throws {
        let store = try tempStore().store
        let id = try store.capture(text: "original", to: .inbox, nowUs: actionTime)
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "CREATE TRIGGER fail_queue BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        #expect(throws: (any Error).self) { try store.editText(itemID: id, text: "changed", baseRev: 0, nowUs: actionTime + 1) }
        #expect(try store.items(in: .all, before: nil, limit: 10).first?.text == "original")
        #expect(throws: ItemActionError.notFound) { try store.editText(itemID: "missing", text: "x", baseRev: 0, nowUs: actionTime + 1) }
        #expect(try ops(store).isEmpty)
    }
}

extension ItemActionsTests {
    @Test func unrelatedPullPreservesPendingTextAndCompletePlace() throws {
        let store = try tempStore().store
        try store.pool.write { try $0.execute(sql: "UPDATE device SET server_url = 'https://notes.example.com'") }
        let id = try store.capture(text: "original", to: .inbox, nowUs: actionTime)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        #expect(try !store.editText(itemID: id, text: "offline", baseRev: 4, nowUs: actionTime + 1))
        try store.move(itemID: id, to: .tunnel, nowUs: actionTime + 2)
        let json = """
        {"items":[{"id":"\(id)","topic_id":null,"text":"remote","capture_time":"2025-10-09T08:53:20Z","deleted_at":null,"purge_at":null,"text_rev":5,"tunnel":false,"attachments":[]}],"topics":[],"tombstones":[],"cursor":1,"has_more":false,"settings":{"trash_after_copy":false}}
        """
        let page = try JSONDecoder().decode(PullPage.self, from: Data(json.utf8))
        _ = try store.applyPull(page, serverURL: "https://notes.example.com")
        let item = try #require(store.items(in: .tunnel, before: nil, limit: 10).first)
        #expect(item.text == "offline")
        #expect(item.editBase == 4)
        #expect(item.topicID == nil)
    }
}

extension ItemActionsTests {
    @Test @MainActor func actionNoticesUseUndoAndRememberTheOriginalTunnelPlace() throws {
        let center = NoticeCenter()
        center.postTrashed(itemID: "i", copied: false)
        #expect(center.current?.message == "Item moved to Trash")
        #expect(center.current?.action == .undoTrash)
        let store = try tempStore().store
        let id = try store.capture(text: "note", to: .inbox, nowUs: 1)
        try center.postMoved(itemID: id, from: .tunnel, store: store)
        #expect(center.current?.action == .undoMove(.tunnel))
        #expect(center.current?.actionTitle == "Undo")
    }
}

extension ItemActionsTests {
    @Test @MainActor func copyingARefusedTunnelCaptureDoesNotQueueTrash() throws {
        let store = try tempStore().store
        let id = try store.capture(text: "refused", to: .tunnel, nowUs: actionTime)
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "UPDATE items SET sync_error = 'invalid' WHERE id = ?", arguments: [id])
        }
        try store.setTrashAfterCopy(true, nowUs: actionTime + 1)
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.copied(try #require(model.items.first)) == .copied)
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).count == 1)
        #expect(try ops(store).map { $0["type"] as! String } == ["SetTrashAfterCopy"])
    }
}

extension ItemActionsTests {
    @Test(arguments: [true, false]) func missingItemsCannotReportSuccessfulTrashOrRestore(_ trash: Bool) throws {
        let store = try tempStore().store
        #expect(throws: ItemActionError.notFound) {
            if trash { try store.trash(itemID: "missing", nowUs: actionTime) }
            else { try store.restore(itemID: "missing", nowUs: actionTime) }
        }
        #expect(try ops(store).isEmpty)
    }
}

extension ItemActionsTests {
    @Test @MainActor func repeatedActionNoticesHaveIndependentDisplayLifetimes() throws {
        let center = NoticeCenter()
        center.postTrashed(itemID: "a")
        let first = try #require(center.current)
        center.postTrashed(itemID: "b")
        let second = try #require(center.current)
        #expect(second.id != first.id)
        center.postTrashed(itemID: "b")
        #expect(center.current?.id != second.id)
    }
}
