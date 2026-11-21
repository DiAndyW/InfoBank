import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NoteBankKit

@MainActor struct ComposerPasteTests {
    @Test func pendingOnlyClearRetiresBarriersButKeepsPhysicalWork() async throws {
        let expected = try Behaviour.rule("composer.clear")
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        let gate = AsyncStream<Void>.makeStream()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            Task {
                for await _ in gate.stream { break }
                completed(nil, CocoaError(.fileReadUnknown))
            }
            return nil
        }
        let old = model.importPaste(provider, type: .png)
        #expect(model.canClear == expected.offered)
        #expect(model.pendingImportCount == 1)
        #expect(model.clear())
        #expect(model.pendingImportCount == 0)
        #expect(!model.canClear)
        #expect(model.isImporting)
        let next = NSItemProvider()
        next.suggestedName = "new.png"
        next.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(Data([2]), nil); return nil
        }
        await model.importPaste(next, type: .png).value
        #expect(model.attachments.map(\.filename) == ["new.png"])
        gate.continuation.yield(())
        gate.continuation.finish()
        await old.value
        #expect(model.error == nil)
        #expect(model.attachments.map(\.filename) == ["new.png"])
        #expect(!model.isImporting)
    }

    @Test func pendingCountsIncludeReadyWaitingSlotsAndFailedClearRetainsThem() async throws {
        let expected = try Behaviour.rule("composer.pending_imports")
        let store = try tempStore().store
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.text = "keep"
        model.flushDraft()
        model.beginImport()
        #expect(model.pendingImportCount == 1)
        #expect(model.pendingImportLabel == expected.label)
        await model.importFile(try AttachmentTests().source(), filename: "second.png")
        #expect(model.pendingImportCount == 2)
        #expect(model.pendingImportLabel == expected.message(["count": "2"]))
        #expect(model.attachments.isEmpty)
        try await store.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_clear BEFORE DELETE ON drafts BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        }
        #expect(!model.clear())
        #expect(model.pendingImportCount == 2)
        #expect(model.text == "keep")
        model.endImport()
        #expect(model.pendingImportCount == 0)
        #expect(model.attachments.map(\.filename) == ["second.png"])
    }

    @Test func acceptedPasteOrderSurvivesReverseCompletionAndFailure() async throws {
        let expected = try Behaviour.rule("composer.attachment_order")
        #expect(expected.order == "input")
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        await model.importFile(try AttachmentTests().source(), filename: "existing.png")
        let gates = (0..<3).map { _ in AsyncStream<Void>.makeStream() }
        var tasks: [Task<Void, Never>] = []
        for index in 0..<3 {
            let provider = NSItemProvider()
            provider.suggestedName = "file-\(index).png"
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
                Task {
                    for await _ in gates[index].stream { break }
                    if index == 1 { completed(nil, CocoaError(.fileReadUnknown)) }
                    else { completed(Data([1, 2, 3]), nil) }
                }
                return nil
            }
            tasks.append(model.importPaste(provider, type: .png))
        }
        for index in [2, 1, 0] {
            gates[index].continuation.yield(())
            gates[index].continuation.finish()
            await tasks[index].value
        }
        #expect(model.attachments.map(\.filename) == ["existing.png", "file-0.png", "file-2.png"])
        #expect(!model.isImporting)
        #expect(model.error != nil)
    }

    @Test func failedClearRetainsCompletedImportsWaitingForEarlierInput() async throws {
        let store = try tempStore().store
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.text = "keep"
        model.flushDraft()
        let gate = AsyncStream<Void>.makeStream()
        let first = NSItemProvider()
        first.suggestedName = "first.png"
        first.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            Task {
                for await _ in gate.stream { break }
                completed(Data([1]), nil)
            }
            return nil
        }
        let older = model.importPaste(first, type: .png)
        let second = NSItemProvider()
        second.suggestedName = "second.png"
        second.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(Data([2]), nil)
            return nil
        }
        await model.importPaste(second, type: .png).value
        try await store.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_clear BEFORE DELETE ON drafts BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        }
        model.clear()
        #expect(model.text == "keep")
        gate.continuation.yield(())
        gate.continuation.finish()
        await older.value
        #expect(model.attachments.map(\.filename) == ["first.png", "second.png"])
        #expect(try store.drafts()[.home]?.attachments.map(\.id) == model.attachments.map(\.id))
    }

    @Test func pickerBatchAcceptedBeforeClearCannotPublishLaterFiles() async throws {
        let store = try tempStore().store
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.text = "clear me"
        model.beginImport()
        model.clear()
        await model.importFile(try AttachmentTests().source(), startsOperation: false)
        model.endImport()
        #expect(model.attachments.isEmpty)
        #expect(try store.drafts()[.home] == nil)
    }

    @Test func latePasteAfterClearCannotResurrectOwnership() async throws {
        let store = try tempStore().store
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.text = "clear me"
        let gate = AsyncStream<Void>.makeStream()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            Task {
                for await _ in gate.stream { break }
                completed(Data([1, 2, 3]), nil)
            }
            return nil
        }
        let task = model.importPaste(provider, type: .png)
        model.clear()
        gate.continuation.yield(())
        gate.continuation.finish()
        await task.value
        #expect(model.attachments.isEmpty)
        #expect(try store.drafts()[.home] == nil)
        #expect(!model.isImporting)
    }

    @Test(arguments: [true, false]) func overlappingImportsAppendFailuresWithoutSuccessClearing(succeeds: Bool) async throws {
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", onCaptured: {})
        let gate = AsyncStream<Void>.makeStream()
        let pending = NSItemProvider()
        pending.suggestedName = "pending.png"
        pending.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            Task {
                for await _ in gate.stream { break }
                if succeeds { completed(Data([1, 2, 3]), nil) }
                else { completed(nil, CocoaError(.fileReadUnknown)) }
            }
            return nil
        }
        let task = model.importPaste(pending, type: .png)
        let failed = NSItemProvider()
        failed.suggestedName = "broken.png"
        failed.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        await model.importPaste(failed, type: .png).value
        let expected = try Behaviour.rule("failure.attach").message(["name": "broken.png"])
        #expect(model.error == expected)
        gate.continuation.yield(())
        gate.continuation.finish()
        await task.value
        let pendingFailure = try Behaviour.rule("failure.attach").message(["name": "pending.png"])
        #expect(model.error == (succeeds ? expected : expected + "\n" + pendingFailure))
        #expect(model.attachments.count == (succeeds ? 1 : 0))
        #expect(!model.isImporting)
    }

    @Test func newPasteClearsWarningWhileAnOlderImportIsPending() async throws {
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", onCaptured: {})
        let gate = AsyncStream<Void>.makeStream()
        let pending = NSItemProvider()
        pending.suggestedName = "pending.png"
        pending.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            Task {
                for await _ in gate.stream { break }
                completed(Data([1, 2, 3]), nil)
            }
            return nil
        }
        let older = model.importPaste(pending, type: .png)
        let failed = NSItemProvider()
        failed.suggestedName = "broken.png"
        failed.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        await model.importPaste(failed, type: .png).value
        let expected = try Behaviour.rule("failure.attach").message(["name": "broken.png"])
        #expect(model.error == expected)
        #expect(model.isImporting)
        let valid = NSItemProvider()
        valid.suggestedName = "new.png"
        valid.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(Data([4, 5, 6]), nil)
            return nil
        }
        let newer = model.importPaste(valid, type: .png)
        #expect(model.error == nil)
        await newer.value
        #expect(model.error == nil)
        #expect(model.attachments.isEmpty)
        #expect(model.isImporting)
        gate.continuation.yield(())
        gate.continuation.finish()
        await older.value
        #expect(model.error == nil)
        #expect(model.attachments.map(\.filename).sorted() == ["new.png", "pending.png"])
        #expect(!model.isImporting)
    }

    @Test func newPickerBatchClearsWarningsWhileAnOlderImportIsPending() async throws {
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", onCaptured: {})
        model.beginImport()
        model.reportImportError("old failure")
        model.beginImport()
        #expect(model.error == nil)
        let valid = try AttachmentTests().source()
        await model.importFile(valid.appendingPathComponent("missing"), filename: "missing.png", startsOperation: false)
        let expected = try #require(model.error)
        #expect(expected.hasPrefix("missing.png failed to attach."))
        await model.importFile(valid, startsOperation: false)
        #expect(model.error == expected)
        #expect(model.attachments.isEmpty)
        model.endImport()
        #expect(model.isImporting)
        model.endImport()
        #expect(model.attachments.count == 1)
        #expect(!model.isImporting)
    }

    @Test func newImportStartClearsOldFailureBeforeCompletion() async throws {
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", onCaptured: {})
        await model.importFile(URL(fileURLWithPath: "/missing-\(UUID().uuidString)"))
        #expect(model.error != nil)
        model.beginImport()
        #expect(model.error == nil)
        model.endImport()
    }

    @Test func mixedPasteKeepsCurrentBatchFailureAndClearsOlderErrors() async throws {
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", onCaptured: {})
        model.reportImportError("old failure")
        let failed = NSItemProvider()
        failed.suggestedName = "broken.png"
        failed.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let failedTask = model.importPaste(failed, type: .png)
        let expected = try Behaviour.rule("failure.attach").message(["name": "broken.png"])
        let valid = NSItemProvider()
        valid.suggestedName = "valid.png"
        valid.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(Data([1, 2, 3]), nil)
            return nil
        }
        let validTask = model.importPaste(valid, type: .png)
        await failedTask.value
        #expect(model.error == expected)
        await validTask.value
        #expect(model.attachments.map(\.filename) == ["valid.png"])
        #expect(model.error == expected)
        await model.importPaste(valid, type: .png).value
        #expect(model.error == nil)
    }

    @Test func mixedFileImportKeepsCurrentBatchFailureAndClearsOnNextSuccess() async throws {
        let model = ComposerModel(store: try tempStore().store, destination: .inbox, placeholder: "", onCaptured: {})
        let valid = try AttachmentTests().source()
        model.beginImport()
        await model.importFile(valid.appendingPathComponent("missing"), filename: "missing.png", startsOperation: false)
        let expected = try #require(model.error)
        #expect(expected.hasPrefix("missing.png failed to attach."))
        await model.importFile(valid, startsOperation: false)
        model.endImport()
        #expect(model.attachments.count == 1)
        #expect(model.error == expected)
        await model.importFile(valid)
        #expect(model.error == nil)
    }

    @Test func unnamedPastesUseUniqueRandomFilenamesWithTheOriginalExtension() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        for name in [nil, "", "   "] as [String?] {
            let provider = NSItemProvider()
            provider.suggestedName = name
            provider.registerDataRepresentation(forTypeIdentifier: UTType.heic.identifier, visibility: .all) { completed in
                completed(Data([1, 2, 3]), nil)
                return nil
            }
            await model.importPaste(provider, type: .heic).value
        }
        #expect(model.attachments.count == 3)
        #expect(Set(model.attachments.map(\.filename)).count == 3)
        for attachment in model.attachments {
            #expect((attachment.filename as NSString).pathExtension == "heic")
            #expect(UUID(uuidString: (attachment.filename as NSString).deletingPathExtension) != nil)
            #expect(try Data(contentsOf: #require(try store.localFile(attachment.id))) == Data([1, 2, 3]))
        }
    }

    @Test func pastedFilesBlockSendUntilImportedAndCaptureWithText() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        model.text = "caption"
        let providers = (0..<3).map { index in
            let provider = NSItemProvider()
            provider.suggestedName = "image-\(index).png"
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
                completed(Data([UInt8(index), 1, 2]), nil)
                return nil
            }
            return provider
        }
        let tasks = providers.map { model.importPaste($0, type: .png) }
        #expect(model.isImporting)
        #expect(!model.canSend)
        #expect(!model.send())
        for task in tasks { await task.value }
        #expect(!model.isImporting)
        #expect(model.canSend)
        #expect(model.attachments.count == 3)
        #expect(model.attachments.map(\.filename).sorted() == ["image-0.png", "image-1.png", "image-2.png"])
        #expect(model.send())
        let captured = try #require(try store.items(in: .inbox, before: nil, limit: 10).first)
        #expect(captured.text == "caption")
        #expect(captured.attachments.count == 3)
        for attachment in captured.attachments {
            let file = try #require(try store.localFile(attachment.id))
            let index = try #require(Int(attachment.filename.dropFirst(6).prefix(1)))
            #expect(try Data(contentsOf: file) == Data([UInt8(index), 1, 2]))
        }
    }

    @Test func failedPasteRetainsDraftAndExistingAttachments() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        model.text = "keep this"
        let original = try store.stageFile(at: AttachmentTests().source())
        model.addAttachments([original])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completed in
            completed(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        await model.importPaste(provider, type: .png).value
        #expect(model.text == "keep this")
        #expect(model.attachments == [original])
        #expect(model.error != nil)
        #expect(!model.isImporting)
        #expect(model.canSend)
    }

    @Test func oversizedPastedFileIsRejectedWithoutChangingTheDraft() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        model.text = "keep this"
        let provider = NSItemProvider()
        provider.suggestedName = "large.png"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completed in
            let file = testDirectory.appending(path: UUID().uuidString + ".png")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try! FileHandle(forWritingTo: file)
            try! handle.truncate(atOffset: UInt64(Store.maxAttachmentBytes + 1))
            try! handle.close()
            completed(file, false, nil)
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        await model.importPaste(provider, type: .png).value
        #expect(model.text == "keep this")
        #expect(model.attachments.isEmpty)
        #expect(model.error == "large.png is over 100 MB")
        #expect(!model.isImporting)
    }

    @Test func pastedFileIsStagedBeforeProviderDeletesItsTemporaryOriginal() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        let provider = NSItemProvider()
        provider.suggestedName = "receipt.pdf"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completed in
            let file = testDirectory.appending(path: UUID().uuidString + ".pdf")
            try! Data("document".utf8).write(to: file)
            completed(file, false, nil)
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        await model.importPaste(provider, type: .pdf).value
        #expect(model.error == nil)
        #expect(model.attachments.first?.filename == "receipt.pdf")
        #expect(model.send())
        let attachment = try #require(try store.items(in: .inbox, before: nil, limit: 10).first?.attachments.first)
        #expect(try Data(contentsOf: #require(try store.localFile(attachment.id))) == Data("document".utf8))
    }
}
