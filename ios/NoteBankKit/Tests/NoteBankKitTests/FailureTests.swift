import Foundation
import GRDB
import Testing
import UniformTypeIdentifiers
@testable import NoteBankKit

@MainActor struct FailureTests {
    @Test func failedRemovalNamesAttachmentAndKeepsItsChipAndFile() throws {
        let store = try tempStore().store
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        let attachment = try store.stageFile(at: AttachmentTests().source(), filename: "receipt.png")
        model.addAttachments([attachment])
        try store.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_remove BEFORE DELETE ON staged_files BEGIN SELECT RAISE(ABORT, 'private data'); END;") }
        model.removeAttachment(attachment.id)
        #expect(model.attachments == [attachment])
        #expect(model.error == "receipt.png failed to remove. NoteBank couldn't read or save its data. Try again.")
        #expect(try store.localFile(attachment.id) != nil)
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER fail_remove") }
        model.removeAttachment(attachment.id)
        #expect(model.attachments.isEmpty)
        #expect(try store.localFile(attachment.id) == nil)
    }

    @Test func sendRetainsTextWithCuratedReason() throws {
        let store = try tempStore().store
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name, deleted_at) VALUES ('missing', 'Gone', 1)") }
        let model = ComposerModel(store: store, destination: .topic("missing"), placeholder: "", onCaptured: {})
        model.text = "keep"
        #expect(!model.send())
        #expect(model.error == (try Behaviour.rule("failure.send").message()) + " This Topic was deleted. Choose another destination.")
        #expect(model.text == "keep")
    }

    @Test func draftFailsAfterThreeAttempts() throws {
        let store = try tempStore().store
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        try store.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_draft BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'private data'); END;") }
        model.text = "keep"
        for _ in 0..<2 { model.flushDraft(); #expect(model.error == nil) }
        model.flushDraft()
        #expect(model.error == (try Behaviour.rule("failure.draft").message()) + " NoteBank couldn't read or save its data. Try again.")
        #expect(model.text == "keep")
    }

    @Test func pasteFailureNamesFileWithoutUnderlyingDetails() async throws {
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", onCaptured: {})
        let provider = NSItemProvider()
        provider.suggestedName = "Pasted image.png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(nil, NSError(domain: "private details", code: 1))
            return nil
        }
        await model.importPaste(provider, type: .png).value
        #expect(model.error == (try Behaviour.rule("failure.attach").message(["name": "Pasted image.png"])))
        #expect(!model.isImporting)
    }

    @Test func missingItemHasSharedReason() throws {
        #expect(ItemActionError.notFound.localizedDescription == (try Behaviour.rule("failure.item_gone").message()))
    }
}
