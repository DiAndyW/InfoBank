import Clocks
import Foundation
import GRDB
import Testing
@testable import NoteBankKit

@MainActor
struct DraftTests {
    @Test func composerOwnershipRecoversAfterRealRestartAndMissingSendKeepsIt() throws {
        let path: URL
        let file: StagedAttachment
        do {
            let (store, url) = try tempStore()
            path = url
            file = try store.stageFile(at: AttachmentTests().source())
            let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
            model.addAttachments([file])
        }
        let store = try Store(at: path, observesSuspension: false)
        let composers = Composers(store: store, onCaptured: {})
        let model = composers.model(for: .inbox, destination: .inbox, placeholder: "")
        #expect(model.attachments == [file])
        let original = try #require(try store.localFile(file.id))
        try FileManager.default.removeItem(at: original)
        #expect(!model.send())
        #expect(model.attachments == [file])
        #expect(model.error == "Item failed to send. An attachment is missing; add it again")
        #expect(try store.drafts()[.inbox]?.attachments == [file])
        model.removeAttachment(file.id)
        #expect(model.attachments.isEmpty)
        #expect(try store.drafts()[.inbox] == nil)
    }

    @Test func composerStagedDeleteFailurePreservesOwnershipAcrossRestart() throws {
        let path: URL
        let file: StagedAttachment
        let original: URL
        do {
            let (store, url) = try tempStore()
            path = url
            file = try store.stageFile(at: AttachmentTests().source())
            original = try #require(try store.localFile(file.id))
            let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
            model.addAttachments([file])
            try store.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse BEFORE DELETE ON staged_files BEGIN SELECT RAISE(ABORT, 'fail'); END") }
            model.removeAttachment(file.id)
            #expect(model.error != nil)
            #expect(model.attachments == [file])
            #expect(try store.drafts()[.inbox]?.attachments == [file])
            #expect(FileManager.default.fileExists(atPath: original.path))
        }
        let store = try Store(at: path, observesSuspension: false)
        let model = Composers(store: store, onCaptured: {}).model(for: .inbox, destination: .inbox, placeholder: "")
        #expect(model.attachments == [file])
        #expect(try store.drafts()[.inbox]?.attachments == [file])
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(throws: (any Error).self) { try store.discardStaged(file.id) }
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER refuse") }
        model.removeAttachment(file.id)
        #expect(model.attachments.isEmpty)
        #expect(try store.drafts()[.inbox] == nil)
        #expect(try store.localFile(file.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func composerAtomicRemovalKeepsCurrentHomeTextAndDestination() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics(id,name) VALUES ('t','Topic')") }
        let file = try store.stageFile(at: AttachmentTests().source())
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.addAttachments([file])
        model.text = "latest"
        model.homeTopicID = "t"
        model.removeAttachment(file.id)
        #expect(try store.drafts()[.home] == Draft(text: "latest", homeTopicID: "t"))
        #expect(try store.localFile(file.id) == nil)
    }

    @Test func editorCancelAndSaveLeaveComposerOwnershipAlone() throws {
        let (store, _) = try tempStore()
        let file = try store.stageFile(at: AttachmentTests().source())
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.addAttachments([file])
        let id = try store.capture(text: "edit me", to: .inbox, nowUs: 1)
        let item = try #require(store.items(in: .inbox, before: nil, limit: 10).first { $0.id == id })
        let editor = ItemEditorModel(store: store, item: item, text: "edit me")
        let editFile = try store.stageFile(at: AttachmentTests().source())
        editor.staging.addAttachments([editFile])
        editor.discard()
        #expect(try store.localFile(editFile.id) == nil)
        editor.text = "saved edit"
        #expect(editor.save(nowUs: 2) == .saved)
        #expect(try store.drafts()[.home]?.attachments == [file])
        #expect(try store.localFile(file.id) != nil)
    }

    @Test func composerOwnsImmediatelyRestoresAndDetaches() throws {
        let (store, _) = try tempStore()
        let file = try store.stageFile(at: AttachmentTests().source())
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        model.addAttachments([file])
        #expect(try store.drafts()[.inbox]?.attachments == [file])
        let restored = Composers(store: store, onCaptured: {}).model(for: .inbox, destination: .inbox, placeholder: "")
        #expect(restored.attachments == [file])
        model.text = "latest"
        model.flushDraft()
        #expect(try store.drafts()[.inbox]?.attachments == [file])
        model.clear()
        #expect(try store.drafts()[.inbox] == nil)
        #expect(try store.localFile(file.id) != nil)
        model.undoClear()
        #expect(try store.drafts()[.inbox]?.attachments == [file])
        model.removeAttachment(file.id)
        #expect(model.attachments.isEmpty)
        #expect(try store.localFile(file.id) == nil)
    }

    @Test func composerFailedOwnershipAndDetachRetainContent() throws {
        let (store, _) = try tempStore()
        let file = try store.stageFile(at: AttachmentTests().source())
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        try store.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'fail'); END") }
        model.addAttachments([file])
        #expect(model.error != nil)
        #expect(model.attachments == [file])
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER refuse") }
        model.flushDraft()
        #expect(try store.drafts()[.inbox]?.attachments == [file])
        try store.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse BEFORE DELETE ON draft_attachments BEGIN SELECT RAISE(ABORT, 'fail'); END") }
        model.clear()
        #expect(model.attachments == [file])
        model.removeAttachment(file.id)
        #expect(model.attachments == [file])
        #expect(try store.localFile(file.id) != nil)
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER refuse") }
    }

    @Test func draftEachPlaceDetachCommitsBeforeBytesAndFailureKeepsOwner() throws {
        let path: URL
        var expected: [DraftPlace: StagedAttachment] = [:]
        do {
            let (store, file) = try tempStore()
            path = file
            try store.pool.write { try $0.execute(sql: "INSERT INTO topics(id,name) VALUES ('t','Topic')") }
            let source = store.directory.appending(path: "source.txt")
            try Data("bytes".utf8).write(to: source)
            for place: DraftPlace in [.home, .inbox, .tunnel, .topic("t")] {
                let a = try store.stageFile(at: source)
                try store.saveDraft(place, text: "", attachmentIDs: [a.id])
                expected[place] = a
            }
        }
        let store = try Store(at: path, observesSuspension: false)
        for (place, a) in expected {
            #expect(try store.drafts()[place]?.attachments == [a])
            try store.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse BEFORE DELETE ON draft_attachments BEGIN SELECT RAISE(ABORT, 'fail'); END") }
            #expect(throws: (any Error).self) { try store.saveDraft(place, text: "", attachmentIDs: []) }
            #expect(throws: (any Error).self) { try store.discardStaged(a.id) }
            #expect(try store.localFile(a.id) != nil)
            try store.pool.write { try $0.execute(sql: "DROP TRIGGER refuse") }
            try store.saveDraft(place, text: "", attachmentIDs: [])
            #expect(try store.localFile(a.id) != nil)
            try store.discardStaged(a.id)
            #expect(try store.localFile(a.id) == nil)
        }
    }

    @Test func draftAttachmentMigrationPreservesTextAndHomeDestination() throws {
        let (_, path) = try tempStore()
        do {
            let pool = try DatabasePool(path: path.path)
            try pool.write { db in
                try db.execute(sql: "DROP TABLE draft_attachments; DROP TABLE drafts; CREATE TABLE drafts(place TEXT PRIMARY KEY, text TEXT NOT NULL CHECK(trim(text) <> ''), home_topic_id TEXT); INSERT INTO topics(id,name) VALUES ('t','Topic'); INSERT INTO drafts VALUES ('home','keep','t'); DELETE FROM grdb_migrations WHERE identifier = 'v12';")
            }
        }
        let store = try Store(at: path, observesSuspension: false)
        #expect(try store.drafts()[.home] == Draft(text: "keep", homeTopicID: "t"))
    }

    @Test func draftOwnedFilesRecoverInOrderAndDenyOtherConsumers() throws {
        let path: URL
        let a: StagedAttachment
        let b: StagedAttachment
        let transient: StagedAttachment
        do {
            let (store, file) = try tempStore()
            path = file
            let source = store.directory.appending(path: "source.txt")
            try Data("bytes".utf8).write(to: source)
            a = try store.stageFile(at: source, filename: "a.txt")
            b = try store.stageFile(at: source, filename: "b.txt")
            transient = try store.stageFile(at: source, filename: "edit.txt")
            try store.saveDraft(.home, text: "", attachmentIDs: [b.id, a.id])
            try store.saveDraft(.home, text: "")
            #expect(throws: (any Error).self) { try store.saveDraft(.inbox, text: "", attachmentIDs: [a.id]) }
            #expect(throws: (any Error).self) { try store.discardStaged(a.id) }
            for draft: DraftPlace? in [nil, .inbox] {
                #expect(throws: (any Error).self) { try store.capture(text: "", attachmentIDs: [a.id], to: .inbox, draft: draft, nowUs: 1) }
            }
            let item = try store.capture(text: "edit", to: .inbox, nowUs: 1)
            #expect(throws: (any Error).self) { try store.editItem(itemID: item, text: "edit", baseRev: 0, adding: [a.id], removing: [], nowUs: 2) }
        }
        let store = try Store(at: path, observesSuspension: false)
        let expected = try Behaviour.rule("composer.draft_attachments")
        #expect((try store.drafts()[.home]?.attachments == [b, a]) == expected.offered)
        #expect(try store.localFile(transient.id) == nil)
        try store.evictCache(nowUs: 100, maxFileBytes: 0)
        #expect(try store.localFile(a.id) != nil)
        try store.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'fail'); END") }
        #expect(throws: (any Error).self) { try store.capture(text: "", attachmentIDs: [b.id, a.id], to: .inbox, draft: .home, nowUs: 3) }
        #expect(try store.drafts()[.home]?.attachments == [b, a])
        #expect(try store.localFile(a.id) != nil)
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER refuse") }
        let original = try #require(try store.localFile(a.id))
        try FileManager.default.removeItem(at: original)
        #expect(try store.drafts()[.home]?.attachments == [b, a])
        do {
            _ = try store.capture(text: "", attachmentIDs: [a.id], to: .inbox, draft: .home, nowUs: 4)
            Issue.record("Missing original must prevent Send")
        } catch {
            #expect(error.localizedDescription == "An attachment is missing; add it again")
        }
        try store.saveDraft(.home, text: "", attachmentIDs: [b.id])
        _ = try store.capture(text: "", attachmentIDs: [b.id], to: .inbox, draft: .home, nowUs: 5)
        #expect(try store.drafts().isEmpty)
        #expect(try store.localFile(b.id) != nil)
        #expect(throws: (any Error).self) { try store.saveDraft(.home, text: "", attachmentIDs: [b.id]) }
        try store.saveDraft(.home, text: "", attachmentIDs: [])
        #expect(try store.drafts().isEmpty)
    }

    @Test func draftMigrationSupportsAttachmentOnlyRows() throws {
        let (store, _) = try tempStore()
        try store.pool.write { db in
            #expect(throws: Never.self) { try db.execute(sql: "INSERT INTO drafts(place,text) VALUES ('inbox','')") }
            #expect(throws: Never.self) { _ = try Row.fetchAll(db, sql: "SELECT attachment_id, place, position FROM draft_attachments") }
        }
    }

    @Test func successfulDraftSavePreservesSendAndImportErrors() throws {
        let store = try tempStore().store
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name, deleted_at) VALUES ('closed', 'Closed', 1)") }
        let model = ComposerModel(store: store, destination: .topic("closed"), placeholder: "", draft: .inbox, onCaptured: {})
        model.text = "Keep this draft"
        #expect(!model.send())
        #expect(model.error == "Item failed to send. " + ItemActionError.topicUnavailable.localizedDescription)
        model.flushDraft()
        #expect(model.error == "Item failed to send. " + ItemActionError.topicUnavailable.localizedDescription)
        #expect(try store.drafts()[.inbox]?.text == "Keep this draft")
        let sendError = "Item failed to send. " + ItemActionError.topicUnavailable.localizedDescription
        model.beginImport()
        #expect(model.error == sendError)
        model.reportImportError("Import failed")
        model.endImport()
        model.flushDraft()
        #expect(model.error == sendError + "\nImport failed")
        model.beginImport()
        #expect(model.error == sendError)
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

    @Test func deletedOrMissingTopicDraftsAreDroppedLiveKept() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: """
            INSERT INTO topics (id, name) VALUES ('live', 'Live');
            INSERT INTO topics (id, name, deleted_at) VALUES ('deleted', 'Deleted', 1);
            """) }
        for id in ["live", "deleted", "missing"] { try store.saveDraft(.topic(id), text: id) }
        let drafts = try store.drafts()
        #expect(Set(drafts.keys) == [.topic("live")])
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM drafts") } == 1)
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
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name, deleted_at) VALUES ('t', 'Topic', 1)") }
        try store.saveDraft(.topic("t"), text: "keep")
        #expect(throws: ItemActionError.topicUnavailable) {
            try store.capture(text: "keep", to: .topic("t"), draft: .topic("t"), nowUs: 1)
        }
        #expect(try store.pool.read { try String.fetchOne($0, sql: "SELECT text FROM drafts WHERE place = 'topic:t'") } == "keep")
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items") } == 0)
    }

    @Test func composerLoadsInitialAndSavesAfterDebounce() async throws {
        let (store, _) = try tempStore()
        let clock = TestClock()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, initial: Draft(text: "a", homeTopicID: nil), clock: clock, onCaptured: {})
        #expect(model.text == "a")
        model.text = "ab"
        await clock.advance(by: .milliseconds(299))
        #expect(try store.drafts()[.inbox] == nil)
        await clock.advance(by: .milliseconds(2))
        #expect(try store.drafts()[.inbox]?.text == "ab")
    }

    @Test func typingAgainRestartsTheDebounce() async throws {
        let (store, _) = try tempStore()
        let clock = TestClock()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, clock: clock, onCaptured: {})
        model.text = "a"
        await clock.advance(by: .milliseconds(200))
        model.text = "ab"
        await clock.advance(by: .milliseconds(299))
        #expect(try store.drafts()[.inbox] == nil)
        await clock.advance(by: .milliseconds(2))
        #expect(try store.drafts()[.inbox]?.text == "ab")
    }

    @Test func sendCancelsPendingSave() async throws {
        let (store, _) = try tempStore()
        let clock = TestClock()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, clock: clock, onCaptured: {})
        model.text = "send"
        #expect(model.send())
        await clock.advance(by: .seconds(1))
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
        let clock = TestClock()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, clock: clock, onCaptured: {})
        model.text = "old"
        model.addAttachments([file])
        model.flushDraft()
        #expect(model.canClear)
        model.clear()
        #expect(model.text.isEmpty && model.attachments.isEmpty && !model.canClear)
        await clock.advance(by: .seconds(1))
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
            INSERT INTO topics (id, name, deleted_at) VALUES ('deleted', 'Deleted', 1);
            """) }
        for id in ["live", "deleted", "missing"] {
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
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name, deleted_at) VALUES ('t', 'Topic', 1)") }
        model.destination = .topic("t")
        #expect(!model.send())
        #expect(model.canClear)
        model.flushDraft()
    }
}
