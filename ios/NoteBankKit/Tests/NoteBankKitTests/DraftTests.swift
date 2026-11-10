import Foundation
import GRDB
import Testing
@testable import NoteBankKit

@MainActor
struct DraftTests {
    @Test func successfulDraftSavePreservesSendAndImportErrors() throws {
        let store = try tempStore().store
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name, archived_at) VALUES ('closed', 'Closed', 1)") }
        let model = ComposerModel(store: store, destination: .topic("closed"), placeholder: "", draft: .inbox, onCaptured: {})
        model.text = "Keep this draft"
        #expect(!model.send())
        #expect(model.error == ItemActionError.topicUnavailable.localizedDescription)
        model.flushDraft()
        #expect(model.error == ItemActionError.topicUnavailable.localizedDescription)
        #expect(try store.drafts()[.inbox]?.text == "Keep this draft")
        model.reportImportError("Import failed")
        model.flushDraft()
        #expect(model.error == "Import failed")
    }

    @Test func saveAndLoadEachPlace() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name) VALUES ('t', 'Topic')") }
        let places: [DraftPlace] = [.home, .inbox, .tunnel, .topic("t")]
        #expect(places.map(\.key) == ["home", "inbox", "tunnel", "topic:t"])
        for place in places { try store.saveDraft(place, text: " original ") }
        try store.saveDraft(.home, text: " updated ", homeTopicID: "t")
        let drafts = try store.drafts()
        #expect(drafts.count == 4)
        #expect(drafts[.home] == Draft(text: " updated ", homeTopicID: "t"))
        for place in places.dropFirst() { #expect(drafts[place] == Draft(text: " original ", homeTopicID: nil)) }
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 0)
    }

    @Test func blankTextDeletes() throws {
        let (store, _) = try tempStore()
        try store.saveDraft(.inbox, text: "old")
        try store.saveDraft(.inbox, text: " \n\t ")
        #expect(try store.drafts().isEmpty)
    }

    @Test func draftsSurviveReopeningTheStore() throws {
        let file: URL
        do {
            let (store, path) = try tempStore()
            file = path
            try store.saveDraft(.tunnel, text: "saved")
        }
        let reopened = try Store(at: file, observesSuspension: false)
        #expect(try reopened.drafts()[.tunnel]?.text == "saved")
    }

    @Test func deletedOrMissingTopicDraftsAreDroppedArchivedKept() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: """
            INSERT INTO topics (id, name) VALUES ('live', 'Live');
            INSERT INTO topics (id, name, archived_at) VALUES ('archived', 'Archived', 1);
            INSERT INTO topics (id, name, deleted_at) VALUES ('deleted', 'Deleted', 1);
            """) }
        for id in ["live", "archived", "deleted", "missing"] { try store.saveDraft(.topic(id), text: id) }
        let drafts = try store.drafts()
        #expect(Set(drafts.keys) == [.topic("live"), .topic("archived")])
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM drafts") } == 2)
    }

    @Test func captureDeletesItsDraft() throws {
        let (store, _) = try tempStore()
        try store.saveDraft(.inbox, text: "send")
        try store.saveDraft(.home, text: "keep")
        let id = try store.capture(text: "send", to: .inbox, draft: .inbox, nowUs: 1)
        #expect(try store.drafts()[.inbox] == nil)
        #expect(try store.drafts()[.home]?.text == "keep")
        #expect(try store.pool.read { try String.fetchOne($0, sql: "SELECT text FROM items WHERE id = ?", arguments: [id]) } == "send")
    }

    @Test func failedCaptureKeepsDraft() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name, archived_at) VALUES ('t', 'Topic', 1)") }
        try store.saveDraft(.topic("t"), text: "keep")
        #expect(throws: ItemActionError.topicUnavailable) {
            try store.capture(text: "keep", to: .topic("t"), draft: .topic("t"), nowUs: 1)
        }
        #expect(try store.drafts()[.topic("t")]?.text == "keep")
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items") } == 0)
    }

    @Test func composerLoadsInitialAndSavesAfterDebounce() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, initial: Draft(text: "a", homeTopicID: nil), onCaptured: {})
        #expect(model.text == "a")
        model.text = "ab"
        #expect(try store.drafts()[.inbox] == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try store.drafts()[.inbox]?.text == "ab")
    }

    @Test func sendCancelsPendingSave() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        model.text = "send"
        #expect(model.send())
        try await Task.sleep(for: .milliseconds(400))
        #expect(try store.drafts()[.inbox] == nil)
        #expect(model.text.isEmpty)
    }

    @Test func homeSavesItsTopic() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name) VALUES ('t', 'Topic')") }
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.homeTopicID = "t"
        model.text = "x"
        model.flushDraft()
        #expect(try store.drafts()[.home]?.homeTopicID == "t")
        model.homeTopicID = nil
        model.flushDraft()
        #expect(try store.drafts()[.home]?.homeTopicID == nil)
    }

    @Test func composersReturnSameModelPerPlace() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name) VALUES ('t', 'Topic')") }
        try store.saveDraft(.home, text: "home", homeTopicID: "t")
        try store.saveDraft(.topic("t"), text: "initial")
        let composers = Composers(store: store, onCaptured: {})
        #expect(composers.home.text == "home")
        #expect(composers.home.homeTopicID == "t")
        let first = composers.model(for: .topic("t"), destination: .topic("t"), placeholder: "first")
        let second = composers.model(for: .topic("t"), destination: .topic("t"), placeholder: "second")
        #expect(first === second)
        #expect(first.placeholder == "second")
        #expect(first.text == "initial")
        first.text = "changed"
        composers.home.text = "new home"
        composers.flush()
        #expect(try store.drafts()[.topic("t")]?.text == "changed")
        #expect(try store.drafts()[.home]?.text == "new home")
    }

    @Test func clearAndUndo() async throws {
        let (store, _) = try tempStore()
        let file = try store.stageFile(at: AttachmentTests().source())
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        model.text = "old"
        model.addAttachments([file])
        model.flushDraft()
        #expect(model.canClear)
        model.clear()
        #expect(model.text.isEmpty && model.attachments.isEmpty && !model.canClear)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try store.drafts()[.inbox] == nil)
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM staged_files WHERE id = ?", arguments: [file.id]) } == 1)
        model.undoClear()
        #expect(model.text == "old" && model.attachments == [file])
        #expect(try store.drafts()[.inbox]?.text == "old")
        let notices = NoticeCenter()
        notices.postCleared(.inbox)
        #expect(notices.current?.message == "Cleared")
        #expect(notices.current?.action == .undoClear(.inbox))
        #expect(notices.current?.actionTitle == "Undo" && notices.current?.itemID == "")
    }

    @Test func undoAfterNewTextDoesNothing() throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        model.text = "old"
        model.clear()
        model.text = "new"
        model.undoClear()
        #expect(model.text == "new")
        model.clear()
        let file = try store.stageFile(at: AttachmentTests().source())
        model.addAttachments([file])
        model.undoClear()
        #expect(model.text.isEmpty && model.attachments == [file])
        model.flushDraft()
    }

    @Test func homeTopicReadsAsInboxUnlessOpen() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: """
            INSERT INTO topics (id, name) VALUES ('live', 'Live');
            INSERT INTO topics (id, name, archived_at) VALUES ('archived', 'Archived', 1);
            INSERT INTO topics (id, name, deleted_at) VALUES ('deleted', 'Deleted', 1);
            """) }
        for id in ["live", "archived", "deleted", "missing"] {
            try store.saveDraft(.home, text: "home", homeTopicID: id)
            #expect(try store.drafts()[.home]?.homeTopicID == (id == "live" ? "live" : nil))
        }
    }

    @Test func cannotClearWhileSending() throws {
        let (store, _) = try tempStore()
        var model: ComposerModel!
        model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {
            model.text = "next"
            #expect(!model.canClear)
            model.clear()
            #expect(model.text == "next")
        })
        model.text = "send"
        #expect(model.send())
        #expect(model.canClear)
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name, archived_at) VALUES ('t', 'Topic', 1)") }
        model.destination = .topic("t")
        #expect(!model.send())
        #expect(model.canClear)
        model.flushDraft()
    }
}
