import Foundation
import GRDB
import Testing
@testable import NoteBankKit

private let t0: Int64 = 1_760_000_000_000_000

@MainActor
struct TunnelTests {
    private func outbox(_ store: Store) throws -> [[String: Any]] {
        try store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT op FROM outbox ORDER BY seq").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        }
    }

    private func types(_ store: Store) throws -> [String] { try outbox(store).map { $0["type"] as! String } }

    private func tunnelItem(_ store: Store) throws -> FeedItem {
        _ = try store.capture(text: "keep", to: .tunnel, nowUs: t0)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        return try store.items(in: .tunnel, before: nil, limit: 10)[0]
    }

    private func setSetting(_ store: Store, _ value: Bool?) throws {
        try store.pool.write { try $0.execute(sql: "UPDATE settings SET trash_after_copy = ?", arguments: [value]) }
    }

    @Test func copiedAsksWhenTheSettingIsUnset() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.copied(item) == .ask)
        #expect(model.items.map(\.id) == [item.id])
        #expect(try outbox(store).isEmpty)
    }

    @Test func copiedWithTheSettingOffLeavesTheItem() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        try setSetting(store, false)
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.copied(item) == .copied)
        #expect(model.items.map(\.id) == [item.id])
        #expect(try outbox(store).isEmpty)
    }

    @Test func copiedWithTheSettingOnTrashesTheItem() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        try setSetting(store, true)
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.copied(item) == .trashed)
        #expect(model.items.isEmpty)
        #expect(try store.items(in: .all, before: nil, limit: 10).isEmpty)
        #expect(try types(store) == ["TrashItem"])
        #expect(try outbox(store)[0]["item_id"] as? String == item.id)
    }

    @Test func answeringYesQueuesTheSettingAndTheTrash() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.answerTrashAfterCopy(true, item: item))
        #expect(try types(store) == ["SetTrashAfterCopy", "TrashItem"])
        #expect(try outbox(store)[0]["value"] as? Bool == true)
        #expect(try store.trashAfterCopy() == true)
        #expect(model.items.isEmpty)
    }

    @Test func answeringNoQueuesOnlyTheSetting() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.answerTrashAfterCopy(false, item: item))
        #expect(try types(store) == ["SetTrashAfterCopy"])
        #expect(try outbox(store)[0]["value"] as? Bool == false)
        #expect(try store.trashAfterCopy() == false)
        #expect(model.items.map(\.id) == [item.id])
    }

    @Test func settingTwiceQueuesOnlyTheLatest() throws {
        let store = try tempStore().store
        try store.setTrashAfterCopy(true, nowUs: t0)
        try store.setTrashAfterCopy(false, nowUs: t0 + 1)
        #expect(try types(store) == ["SetTrashAfterCopy"])
        #expect(try outbox(store)[0]["value"] as? Bool == false)
        #expect(try store.trashAfterCopy() == false)
    }

    @Test func undoQueuesARestoreAndTheItemIsBackInTheTunnel() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        try setSetting(store, true)
        let model = FeedModel(store: store, place: .tunnel)
        _ = model.copied(item)
        model.undoTrash(itemID: item.id)
        #expect(try types(store) == ["TrashItem", "RestoreItem"])
        #expect(model.items.map(\.id) == [item.id])
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).map(\.id) == [item.id])
    }

    @Test func noticeCenterPostsTheTrashedNoticeWithUndo() {
        let center = NoticeCenter()
        center.postTrashed(itemID: "a")
        #expect(center.current?.message == "Copied, moved to Trash")
        #expect(center.current?.itemID == "a")
        #expect(center.current?.action == .undoTrash)
    }
    @Test func aFailedTrashAnswerDoesNotReportSuccess() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        let model = FeedModel(store: store, place: .tunnel)
        try store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_trash BEFORE UPDATE OF deleted_at ON items
                WHEN NEW.deleted_at IS NOT NULL BEGIN SELECT RAISE(FAIL, 'Trash unavailable'); END
                """)
        }
        #expect(!model.answerTrashAfterCopy(true, item: item))
        #expect(model.loadError == "NoteBank couldn't read or save its data. Try again.")
        #expect(try types(store) == ["SetTrashAfterCopy"])
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).map(\.id) == [item.id])
    }

    @Test func menuCopyUsesShownPreferenceAfterSettingChanges() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        try setSetting(store, false)
        let model = FeedModel(store: store, place: .tunnel)
        let shown = model.trashAfterCopy
        try setSetting(store, true)
        #expect(model.copied(item, preference: shown) == .copied)
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).count == 1)
    }

    @Test func feedObservesCopyPreferenceAndPreservesUnanswered() async throws {
        let store = try tempStore().store
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.trashAfterCopy == nil)
        try store.setTrashAfterCopy(true, nowUs: t0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.trashAfterCopy == true)
        try store.setTrashAfterCopy(false, nowUs: t0 + 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.trashAfterCopy == false)
    }

    @Test func unansweredMenuCopyStillAsksAndAnswerIsRemembered() throws {
        let store = try tempStore().store
        let item = try tunnelItem(store)
        let model = FeedModel(store: store, place: .tunnel)
        #expect(model.copied(item, preference: nil) == .ask)
        #expect(model.answerTrashAfterCopy(false, item: item))
        #expect(model.copied(item) == .copied)
    }

}
