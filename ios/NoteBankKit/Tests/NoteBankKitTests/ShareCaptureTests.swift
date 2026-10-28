import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct ShareCaptureTests {
    @Test func sharePushAcknowledgesOnlyItsCaptureAndPreservesOtherWork() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let unrelated = try store.capture(text: "other draft", to: .inbox, nowUs: Time.nowUs())
        let shared = try store.capture(text: "https://example.com", to: .inbox, nowUs: Time.nowUs())
        try await pushSharedCapture(shared, store: store, secrets: secrets)
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 1)
        let (other, _) = try tempStore()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        var notices: [SyncNotice] = []
        _ = try await cycle(store: other, secrets: secrets, http: .live, queued: &notices)
        #expect(try other.items(in: .inbox, before: nil, limit: 10).map(\.id) == [shared])
        #expect(try store.items(in: .inbox, before: nil, limit: 10).contains { $0.id == unrelated })
        try await pushSharedCapture(shared, store: store, secrets: secrets)
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 1)
    }

    @Test func failedSharePushRetainsLocalCaptureAndOriginal() async throws {
        let server = try await FakeServer { _ in .init(status: 503) }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        let item = try store.capture(text: "", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        await #expect(throws: (any Error).self) { try await pushSharedCapture(item, store: store, secrets: secrets) }
        #expect(try store.items(in: .inbox, before: nil, limit: 10).first?.id == item)
        #expect(try store.localFile(file.id) != nil)
        #expect(try store.pendingUploads().isEmpty)
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 1)
    }

    @Test @MainActor func shareDraftPreservesOrderAndCannotSavePartialImportsOrSaveTwice() throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        model.beginImport()
        model.appendText("first")
        model.appendText("https://example.com")
        model.extraText = "my comment"
        #expect(!model.canSave)
        #expect(model.save() == nil)
        model.endImport()
        let id = try #require(model.save())
        #expect(model.save() == id)
        #expect(try store.items(in: .inbox, before: nil, limit: 10).first?.text == "first\n\nhttps://example.com\n\nmy comment")
        #expect(try store.items(in: .inbox, before: nil, limit: 10).count == 1)
    }

    @Test @MainActor func shareDraftExcludesArchivedTopicsAndCancelDiscardsOnlyItsFiles() throws {
        let (store, _) = try tempStore()
        let active = try store.createTopic(name: "Active", nowUs: 1)
        let archived = try store.createTopic(name: "Archived", nowUs: 1)
        try store.setTopicArchived(archived, archived: true, nowUs: 2)
        let own = try store.stageFile(at: AttachmentTests().source())
        let other = try store.stageFile(at: AttachmentTests().source())
        let model = ShareCaptureModel(store: store)
        #expect(model.topics.map(\.id) == [active])
        model.addAttachment(own)
        model.cancel()
        #expect(try store.localFile(own.id) == nil)
        #expect(try store.localFile(other.id) != nil)
    }
}

extension ShareCaptureTests {
    @Test @MainActor func importsURLsAndFileRepresentationsInInputOrder() async throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let url = NSItemProvider(item: NSURL(string: "https://example.com/article")!, typeIdentifier: "public.url")
        let text = NSItemProvider(item: "selected words" as NSString, typeIdentifier: "public.plain-text")
        let fileURL = try AttachmentTests().source(Data("shared file".utf8), name: "shared.txt")
        let file = NSItemProvider()
        file.suggestedName = "shared.txt"
        file.registerFileRepresentation(forTypeIdentifier: "public.plain-text", fileOptions: [], visibility: .all) { completion in
            completion(fileURL, false, nil)
            return nil
        }
        await importSharedInputs([url, text, file], store: store, model: model)
        #expect(model.sharedText == "https://example.com/article\n\nselected words")
        #expect(model.attachments.map(\.filename) == ["shared.txt"])
        let id = try #require(model.save())
        let item = try #require(try store.items(in: .inbox, before: nil, limit: 10).first)
        #expect(item.id == id)
        #expect(item.attachments.count == 1)
        #expect(try Data(contentsOf: store.localFile(item.attachments[0].id)!) == Data("shared file".utf8))
    }

    @Test @MainActor func failedImportCannotSilentlySaveOnlySuccessfulInputs() async throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let text = NSItemProvider(item: "keep" as NSString, typeIdentifier: "public.plain-text")
        await importSharedInputs([text, NSItemProvider()], store: store, model: model)
        #expect(model.sharedText == "keep")
        #expect(!model.canSave)
        #expect(model.save() == nil)
        #expect(model.error != nil)
        #expect(try store.items(in: .all, before: nil, limit: 10).isEmpty)
    }
}

extension ShareCaptureTests {
    @Test func deliveryDeadlineLeavesCaptureQueuedForMainApp() async throws {
        let server = try await FakeServer { _ in
            Thread.sleep(forTimeInterval: 0.4)
            return .init(status: 503)
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let item = try store.capture(text: "offline-safe", to: .inbox, nowUs: 1)
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false, sessionIdentifier: AttachmentTransfers.shareSessionIdentifier)
        let start = ContinuousClock.now
        let result = await deliverSharedCapture(item, store: store, secrets: secrets, transfers: transfers, timeout: .milliseconds(50))
        #expect(result == .savedLocally)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 1)
    }

    @Test func sharedFileReachesOtherDeviceWithoutForegroundSync() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        let item = try store.capture(text: "shared", attachmentIDs: [file.id], to: .inbox, nowUs: Time.nowUs())
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false, sessionIdentifier: AttachmentTransfers.shareSessionIdentifier)
        let result = await deliverSharedCapture(item, store: store, secrets: secrets, transfers: transfers)
        #expect(result == .sent)
        for _ in 0..<200 {
            if try store.attachment(file.id)?.uploaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try store.attachment(file.id)?.uploaded == true)
        let (other, _) = try tempStore()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        var notices: [SyncNotice] = []
        _ = try await cycle(store: other, secrets: secrets, http: .live, queued: &notices)
        #expect(try other.items(in: .inbox, before: nil, limit: 10).first?.id == item)
        let downloads = AttachmentTransfers(store: other, secrets: secrets, background: false)
        let downloaded = try await downloads.open(file.id)
        #expect(try Data(contentsOf: downloaded) == Data("hello".utf8))
        await downloads.release(file.id)
    }
}

extension ShareCaptureTests {
    @Test func malformedShareAcknowledgementDoesNotLoseOutboxWork() async throws {
        let server = try await FakeServer { _ in .json("{\"results\":[{\"op_id\":\"wrong-operation\",\"status\":\"accepted\"}]}") }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let item = try store.capture(text: "must survive", to: .inbox, nowUs: 1)
        await #expect(throws: (any Error).self) { try await pushSharedCapture(item, store: store, secrets: secrets) }
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 1)
    }

    @Test func sharedCaptureToRemotelyArchivedTopicReportsInbox() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let topic = try store.createTopic(name: "Closed elsewhere", nowUs: Time.nowUs())
        var notices: [SyncNotice] = []
        _ = try await cycle(store: store, secrets: secrets, http: .live, queued: &notices)
        let (other, _) = try tempStore()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        _ = try await cycle(store: other, secrets: secrets, http: .live, queued: &notices)
        try other.setTopicArchived(topic, archived: true, nowUs: Time.nowUs())
        _ = try await cycle(store: other, secrets: secrets, http: .live, queued: &notices)
        let item = try store.capture(text: "keep this", to: .topic(topic), nowUs: Time.nowUs())
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false, sessionIdentifier: AttachmentTransfers.shareSessionIdentifier)
        #expect(await deliverSharedCapture(item, store: store, secrets: secrets, transfers: transfers) == .sentToInbox)
        #expect(try store.items(in: .inbox, before: nil, limit: 10).first?.id == item)
    }

    @Test @MainActor func oversizedTextKeepsDraftAndFilesForCorrection() throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let file = try store.stageFile(at: AttachmentTests().source())
        model.addAttachment(file)
        model.extraText = String(repeating: "a", count: (1 << 20) + 1)
        #expect(model.save() == nil)
        #expect(model.attachments == [file])
        #expect(model.error != nil)
        #expect(try store.localFile(file.id) != nil)
        model.extraText = "corrected"
        #expect(model.save() != nil)
    }

    @Test @MainActor func imageImportKeepsBytesAndAddsFileExtension() async throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let url = try AttachmentTests().source(Data([137, 80, 78, 71]), name: "temporary")
        let provider = NSItemProvider()
        provider.suggestedName = "photo"
        provider.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        await importSharedInputs([provider], store: store, model: model)
        #expect(model.attachments.map(\.filename) == ["photo.png"])
        let file = try #require(model.attachments.first)
        #expect(file.mimeType == "image/png")
        #expect(try Data(contentsOf: store.localFile(file.id)!) == Data([137, 80, 78, 71]))
    }
}

extension ShareCaptureTests {
    @Test func serverRefusalIsReportedAndOriginalRemainsAvailable() async throws {
        let server = try await FakeServer { request in
            let body = try! JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            let op = (body["ops"] as! [[String: Any]])[0]
            return .json("{\"results\":[{\"op_id\":\"\(op["id"] as! String)\",\"status\":\"rejected\",\"reason\":\"invalid\"}]}")
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        let item = try store.capture(text: "saved", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false, sessionIdentifier: AttachmentTransfers.shareSessionIdentifier)
        #expect(await deliverSharedCapture(item, store: store, secrets: secrets, transfers: transfers) == .refused)
        #expect(await deliverSharedCapture(item, store: store, secrets: secrets, transfers: transfers) == .refused)
        #expect(try store.localFile(file.id) != nil)
        #expect(try store.pendingUploads().isEmpty)
        #expect(try await store.pool.read { try String.fetchOne($0, sql: "SELECT sync_error FROM items WHERE id = ?", arguments: [item]) } == "invalid")
    }

    @Test @MainActor func fileURLRepresentationIsImportedAsAttachment() async throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let file = try AttachmentTests().source()
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: "public.file-url")
        await importSharedInputs([provider], store: store, model: model)
        #expect(model.sharedText.isEmpty)
        #expect(model.attachments.map(\.filename) == ["test.txt"])
        #expect(model.canSave)
    }
}

extension ShareCaptureTests {
    @Test @MainActor func linkWithGenericDataAlternativeStillSavesAsText() async throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let provider = NSItemProvider()
        provider.suggestedName = "example.com"
        provider.registerDataRepresentation(forTypeIdentifier: "public.plain-text", visibility: .all) { completion in
            completion(Data("A web page".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: "public.data", visibility: .all) { completion in
            completion(Data("https://example.com/shared".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: "public.url", visibility: .all) { completion in
            completion(Data("https://example.com/shared".utf8), nil)
            return nil
        }
        await importSharedInputs([provider], store: store, model: model)
        #expect(model.sharedText == "https://example.com/shared")
        #expect(model.attachments.isEmpty)
        #expect(model.canSave)
    }
}
