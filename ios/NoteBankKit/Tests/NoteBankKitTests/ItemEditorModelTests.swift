import Foundation
import GRDB
import Testing
import UniformTypeIdentifiers
@testable import NoteBankKit

@MainActor struct ItemEditorModelTests {
    private func fixture() throws -> (Store, FeedItem) {
        let store = try tempStore().store
        let id = try store.capture(text: "original", to: .inbox, nowUs: 1)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO attachments VALUES ('a', ?, 'file.pdf', 'application/pdf', 1, 1, 0)", arguments: [id])
            try db.execute(sql: "DELETE FROM outbox")
        }
        return (store, try #require(store.items(in: .inbox, before: nil, limit: 10).first))
    }

    private func opTypes(_ store: Store) throws -> [String] {
        try store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT op FROM outbox ORDER BY seq").map {
                try (JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["type"] as! String
            }
        }
    }

    @Test func storeRestoresBeforeRemovingWhenTextUnchanged() throws {
        let (store, item) = try fixture()
        try store.trash(itemID: item.id, nowUs: 2)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        #expect(try !store.editItem(itemID: item.id, text: "original", baseRev: item.editBase, adding: [], removing: ["a"], nowUs: 3))
        #expect(try opTypes(store) == ["RestoreItem", "RemoveAttachment"])
        #expect(try store.items(in: .inbox, before: nil, limit: 10).first?.attachments.isEmpty == true)
    }

    @Test func storeEmptiedTrashPreservesDeadlineAndContent() throws {
        let (store, item) = try fixture()
        try store.pool.write { db in
            try db.execute(sql: "UPDATE items SET deleted_at = 2, purge_at = 123 WHERE id = ?", arguments: [item.id])
        }
        #expect(try store.editItem(itemID: item.id, text: "  ", baseRev: item.editBase, adding: [], removing: ["a"], nowUs: 3))
        let row = try store.pool.read { try #require(try Row.fetchOne($0, sql: "SELECT * FROM items WHERE id = ?", arguments: [item.id])) }
        #expect(row["deleted_at"] as Int64? == 2)
        #expect(row["purge_at"] as Int64? == 123)
        #expect(row["text"] as String == "original")
        #expect(try opTypes(store).isEmpty)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM attachments WHERE item_id = ?", arguments: [item.id]) } == 1)
    }
}

extension ItemEditorModelTests {
    @Test func emptyRule() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        model.text = " \n "
        model.remove("a")
        #expect(model.isEmpty)
        let rule = try Behaviour.rule("editor.empty")
        #expect(ItemEditorModel.trashTitle == rule.message())
        #expect(ItemEditorModel.moveToTrash == rule.label)
        #expect([ItemEditorModel.cancel, ItemEditorModel.moveToTrash] == rule.actions)
        #expect(model.save(nowUs: 2) == .trashed)
        #expect(try opTypes(store) == ["TrashItem"])
    }

    @Test func discardRule() throws {
        let rule = try Behaviour.rule("editor.discard")
        let searchRule = try Behaviour.rule("search.enter")
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        #expect(!model.hasChanges)
        model.staging.beginImport()
        #expect(model.hasChanges == rule.offered)
        model.staging.endImport()
        model.remove("a")
        #expect(model.hasChanges == rule.offered)
        #expect(rule.offered == true)
        #expect(ItemEditorModel.discardTitle == rule.message())
        #expect([ItemEditorModel.keepEditing, ItemEditorModel.discardAction] == rule.actions)
    }

    @Test func hasChangesCountsAttachments() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "opening conflict text")
        #expect(!model.hasChanges)
        model.text += " "
        #expect(model.hasChanges)
        model.text = "opening conflict text"
        #expect(!model.hasChanges)
        model.remove("unknown")
        #expect(!model.hasChanges)
        model.remove("a")
        #expect(model.hasChanges)
        #expect(model.kept.isEmpty)
        #expect(!model.isEmpty)
    }

    @Test func pasteAttaches() async throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        let provider = NSItemProvider()
        provider.suggestedName = "receipt.pdf"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completed in
            let file = testDirectory.appending(path: UUID().uuidString + ".pdf")
            try! Data("document".utf8).write(to: file)
            completed(file, false, nil)
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        await model.staging.importPaste(provider, type: .pdf).value
        #expect((model.staging.attachments.count == 1) == (try Behaviour.rule("editor.paste").offered))
        #expect(model.hasChanges)
        model.text = ""
        model.remove("a")
        #expect(!model.isEmpty)
        let staged = try #require(model.staging.attachments.first)
        #expect(model.save(nowUs: 3) == .saved)
        let saved = try #require(store.items(in: .inbox, before: nil, limit: 10).first)
        #expect(saved.text == nil)
        #expect(saved.attachments.map(\.id) == [staged.id])
        #expect(try opTypes(store) == ["AddAttachment", "SetText", "RemoveAttachment"])
        model.discard()
        #expect(try store.localFile(staged.id) != nil)
    }

    @Test func cannotSaveWhileImporting() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "edited")
        #expect(model.canSave)
        model.staging.beginImport()
        #expect(!model.canSave)
        #expect(model.save(nowUs: 2) == nil)
        #expect(try opTypes(store).isEmpty)
        #expect(try store.items(in: .inbox, before: nil, limit: 10).first?.text == "original")
        model.staging.endImport()
        #expect(model.canSave)
    }

    @Test(arguments: [true, false]) func saveRestoresTrashed(_ changeText: Bool) throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        try store.trash(itemID: item.id, nowUs: 2)
        try store.pool.write { db in
            try db.execute(sql: "UPDATE items SET purge_at = 123 WHERE id = ?", arguments: [item.id])
            try db.execute(sql: "DELETE FROM outbox")
        }
        if changeText { model.text = "edited" }
        else { model.remove("a") }
        #expect((model.save(nowUs: 3) == .saved) == (try Behaviour.rule("editor.save_restores").offered))
        let restored = try #require(store.items(in: .inbox, before: nil, limit: 10).first)
        #expect(restored.text == (changeText ? "edited" : "original"))
        #expect(try store.pool.read { try Int64.fetchOne($0, sql: "SELECT purge_at FROM items WHERE id = ?", arguments: [item.id]) } == nil)
        #expect(try opTypes(store) == (changeText ? ["SetText"] : ["RestoreItem", "RemoveAttachment"]))
    }

    @Test func emptiedTrashedStaysPut() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        try store.pool.write { try $0.execute(sql: "UPDATE items SET deleted_at = 2, purge_at = 123 WHERE id = ?", arguments: [item.id]) }
        model.text = ""
        model.remove("a")
        #expect(model.save(nowUs: 4) == .trashed)
        let row = try store.pool.read { try #require(try Row.fetchOne($0, sql: "SELECT * FROM items WHERE id = ?", arguments: [item.id])) }
        #expect(row["deleted_at"] as Int64? == 2)
        #expect(row["purge_at"] as Int64? == 123)
        #expect(try opTypes(store).isEmpty)
    }

    @Test func goneKeepsText() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        model.text = "keep my edit"
        try store.pool.write { try $0.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [item.id]) }
        #expect(model.save(nowUs: 2) == nil)
        #expect(model.error == (try Behaviour.rule("failure.edit").message()) + " " + (try Behaviour.rule("failure.item_gone").message()))
        #expect(model.text == "keep my edit")
    }

    @Test func tooLongKeepsTextAndCanRetry() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        let text = String(repeating: "x", count: Store.maxItemTextBytes + 1)
        model.text = text
        #expect(model.save(nowUs: 2) == nil)
        #expect(model.error == (try Behaviour.rule("failure.edit").message()) + " That's too long to save (1 MB max)")
        #expect(model.text == text)
        #expect(try opTypes(store).isEmpty)
        model.text = "retry"
        #expect(model.save(nowUs: 3) == .saved)
        #expect(model.error == nil)
    }

    @Test func stagedRemovalAndDiscardUnstageFiles() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        let first = try store.stageFile(at: AttachmentTests().source())
        let second = try store.stageFile(at: AttachmentTests().source())
        model.staging.addAttachments([first, second])
        model.remove(first.id)
        #expect(model.staging.attachments == [second])
        #expect(try store.localFile(first.id) == nil)
        model.discard()
        #expect(model.staging.attachments.isEmpty)
        #expect(try store.localFile(second.id) == nil)
        #expect(model.kept == item.attachments)
        #expect(try opTypes(store).isEmpty)
    }

    @Test func clearRule() throws {
        let rule = try Behaviour.rule("editor.clear")
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "original")
        let staged = try store.stageFile(at: AttachmentTests().source())
        model.staging.addAttachments([staged])
        #expect(rule.offered == true)
        #expect(ItemEditorModel.clearLabel == rule.label)
        model.clear()
        #expect(model.isEmpty)
        #expect(model.hasChanges)
        #expect(try store.localFile(staged.id) == nil)
        #expect(try opTypes(store).isEmpty)
        #expect(model.save(nowUs: 2) == .trashed)
        #expect(try opTypes(store) == ["TrashItem"])
    }

    @Test func refusedItemCannotBeEdited() throws {
        let (store, item) = try fixture()
        let model = ItemEditorModel(store: store, item: item, text: "changed")
        try store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = 'invalid', deleted_at = 2 WHERE id = ?", arguments: [item.id]) }
        #expect(model.save(nowUs: 3) == nil)
        #expect(model.error == (try Behaviour.rule("failure.edit").message()) + " " + (try Behaviour.rule("failure.item_gone").message()))
        #expect(try opTypes(store).isEmpty)
    }
}

extension ItemEditorModelTests {
    @Test(arguments: [true, false]) func composerDraftAndFileSurviveEditing(save: Bool) throws {
        let (store, item) = try fixture()
        let composers = Composers(store: store, onCaptured: {})
        let composer = composers.model(for: .inbox, destination: .inbox, placeholder: "Capture")
        composer.text = "unfinished capture"
        let file = try store.stageFile(at: AttachmentTests().source())
        composer.addAttachments([file])
        composer.flushDraft()
        let editor = ItemEditorModel(store: store, item: item, text: "original")
        editor.text = "edited"
        if save { #expect(editor.save(nowUs: 4) == .saved) }
        else { editor.discard() }
        let returned = composers.model(for: .inbox, destination: .inbox, placeholder: "Capture")
        #expect(returned === composer)
        #expect(returned.text == "unfinished capture")
        #expect(returned.attachments == [file])
        #expect(try store.drafts()[.inbox]?.text == "unfinished capture")
        #expect(try store.localFile(file.id) != nil)
    }
}

extension ItemEditorModelTests {
    @Test func leaveDecisionRule() throws {
        let rule = try Behaviour.rule("editor.discard")
        let searchRule = try Behaviour.rule("search.enter")
        let (store, item) = try fixture()
        let navigation = EditorNavigation()
        let unchanged = ItemEditorModel(store: store, item: item, text: "original")
        var ended = 0
        var proceeded = 0
        navigation.begin(unchanged) { done in ended += 1; done() }
        navigation.requestLeave { proceeded += 1 }
        #expect(proceeded == 1)
        #expect(ended == 1)
        #expect(!navigation.confirmingLeave)
        let changed = ItemEditorModel(store: store, item: item, text: "original")
        changed.text = "keep this text"
        let file = try store.stageFile(at: AttachmentTests().source())
        let fileURL = try #require(try store.localFile(file.id))
        changed.staging.addAttachments([file])
        navigation.begin(changed) { done in ended += 1; done() }
        navigation.requestLeave { proceeded += 1 }
        #expect(navigation.confirmingLeave == rule.offered)
        #expect(navigation.confirmingLeave == searchRule.offered)
        #expect(proceeded == 1)
        navigation.keepEditing()
        #expect(!navigation.confirmingLeave)
        #expect(navigation.editor === changed)
        #expect(changed.text == "keep this text")
        #expect(changed.staging.attachments == [file])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(proceeded == 1)
        navigation.requestLeave { proceeded += 1 }
        changed.staging.beginImport()
        navigation.discardAndLeave()
        #expect(proceeded == 1)
        #expect(navigation.confirmingLeave)
        changed.staging.endImport()
        navigation.discardAndLeave()
        #expect(proceeded == 2)
        #expect(ended == 2)
        #expect(navigation.editor == nil)
        #expect(changed.staging.attachments.isEmpty)
        #expect(try store.localFile(file.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(ItemEditorModel.discardTitle == rule.message())
        #expect([ItemEditorModel.keepEditing, ItemEditorModel.discardAction] == rule.actions)
    }
}

extension ItemEditorModelTests {
    @Test(arguments: [true, false]) func deletedTopicKeepsEditorUntilDiscard(keepItems: Bool) throws {
        let store = try tempStore().store
        let topic = try store.createTopic(name: "Temporary", nowUs: 1)
        _ = try store.capture(text: "original", to: .topic(topic), nowUs: 2)
        let item = try #require(store.items(in: .topic(topic), before: nil, limit: 10).first)
        let editor = ItemEditorModel(store: store, item: item, text: "original")
        editor.text = "still available to copy"
        let file = try store.stageFile(at: AttachmentTests().source())
        editor.staging.addAttachments([file])
        let navigation = EditorNavigation()
        var feedPresent = true
        navigation.begin(editor) { $0() }
        _ = try store.deleteTopic(topic, keeping: keepItems ? .all : .none, nowUs: 3)
        navigation.requestLeave { feedPresent = false }
        #expect(navigation.confirmingLeave == (try Behaviour.rule("editor.discard").offered))
        #expect(feedPresent)
        navigation.keepEditing()
        #expect(feedPresent)
        #expect(navigation.editor === editor)
        #expect(editor.text == "still available to copy")
        #expect(try store.localFile(file.id) != nil)
        navigation.requestLeave { feedPresent = false }
        navigation.discardAndLeave()
        #expect(!feedPresent)
        #expect(try store.localFile(file.id) == nil)
    }
}


extension ItemEditorModelTests {
    @Test(arguments: [true, false]) func navigationWaitsForNativeClose(dirty: Bool) throws {
        let (store, item) = try fixture()
        let editor = ItemEditorModel(store: store, item: item, text: "original")
        if dirty { editor.text = "changed" }
        let navigation = EditorNavigation()
        var closeStarted = 0
        var navigated = 0
        var completion: (() -> Void)?
        navigation.begin(editor) { done in closeStarted += 1; completion = done }
        navigation.requestLeave { navigated += 1 }
        if dirty {
            #expect(navigation.confirmingLeave)
            navigation.discardAndLeave()
        }
        #expect(closeStarted == 1)
        #expect(navigated == 0)
        #expect(navigation.editor === editor)
        navigation.requestLeave { navigated += 10 }
        navigation.end()
        #expect(closeStarted == 1)
        #expect(!navigation.confirmingLeave)
        completion?()
        #expect(navigated == 11)
        #expect(navigation.editor == nil)
        completion?()
        #expect(navigated == 11)
        navigation.requestLeave { navigated += 100 }
        #expect(navigated == 111)
    }
}
