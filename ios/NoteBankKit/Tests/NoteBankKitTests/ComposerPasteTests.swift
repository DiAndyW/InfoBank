import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NoteBankKit

@MainActor struct ComposerPasteTests {
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
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
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
        #expect(model.error != nil)
        #expect(!model.isImporting)
    }

    @Test func pastedFileIsStagedBeforeProviderDeletesItsTemporaryOriginal() async throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        let provider = NSItemProvider()
        provider.suggestedName = "receipt.pdf"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completed in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".pdf")
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
