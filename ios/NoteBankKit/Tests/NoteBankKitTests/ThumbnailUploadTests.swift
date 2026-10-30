import Foundation
import ImageIO
import Synchronization
import Testing
@testable import NoteBankKit

struct ThumbnailUploadTests {
    @Test func previewsWaitForOriginalAndMetadataAcknowledgement() async throws {
        let server = try await FakeServer { _ in
            Issue.record("Unacknowledged attachments must not make upload requests")
            return .init(status: 500)
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let source = try #require(Bundle.module.url(forResource: "synthetic", withExtension: "heic", subdirectory: "Fixtures"))
        let staged = try store.stageFile(at: source)
        _ = try store.capture(text: "HEIC", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        try await transfers.synchronize()
        #expect(server.requests(to: "/attachments/\(staged.id)/thumbnail-upload-token") == 0)
        #expect(try store.attachment(staged.id)?.hasThumbnail == false)
        #expect(try store.localFile(staged.id) != nil)
    }

    @Test func staleThumbnailCompletionCannotPublishIntoAnotherGeneration() async throws {
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        let server = try await FakeServer { request in
            if request.path.hasSuffix("thumbnail-upload-token") { return .json("{\"token\":\"thumbnail-only\"}") }
            try! store.pool.write { db in try db.execute(sql: "UPDATE device SET transfer_generation = transfer_generation + 1") }
            return .init(status: 204)
        }
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let source = try #require(Bundle.module.url(forResource: "synthetic", withExtension: "heic", subdirectory: "Fixtures"))
        let staged = try store.stageFile(at: source)
        _ = try store.capture(text: "HEIC", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
        try await store.pool.write { db in
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "UPDATE attachments SET uploaded = 1 WHERE id = ?", arguments: [staged.id])
        }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        try await transfers.synchronize()
        #expect(server.requests(to: "/attachments/\(staged.id)/thumbnail") == 1)
        #expect(try store.attachment(staged.id)?.hasThumbnail == false)
        #expect(try store.attachment(staged.id)?.uploaded == true)
    }

    @Test func HEICPreviewSyncsToAnotherDeviceWithoutDownloadingTheOriginal() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let source = try #require(Bundle.module.url(forResource: "synthetic", withExtension: "heic", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: source)
        let staged = try store.stageFile(at: source)
        _ = try store.capture(text: "HEIC", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
        var notices: [SyncNotice] = []
        _ = try await cycle(store: store, secrets: secrets, http: .live, queued: &notices)
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        try await transfers.synchronize()
        for _ in 0..<200 {
            if try store.attachment(staged.id)?.uploaded == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await transfers.synchronize()
        _ = try await cycle(store: store, secrets: secrets, http: .live, queued: &notices)
        #expect(try store.attachment(staged.id)?.hasThumbnail == true)
        let (other, _) = try tempStore(); let otherSecrets = SecretStore.memory()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: otherSecrets)
        _ = try await cycle(store: other, secrets: otherSecrets, http: .live, queued: &notices)
        #expect(try other.attachment(staged.id)?.hasThumbnail == true)
        let downloads = AttachmentTransfers(store: other, secrets: otherSecrets, background: false)
        let thumbnail = try #require(try await downloads.thumbnail(staged.id))
        let bytes = try Data(contentsOf: thumbnail)
        #expect(bytes.prefix(2) == Data([0xff, 0xd8]))
        let decoded = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(max(image.width, image.height) <= 400)
        #expect(try other.localFile(staged.id) == nil)
        #expect(try Data(contentsOf: #require(try store.localFile(staged.id))) == original)
    }

    @Test func failedPreviewUploadBacksOffAndRetriesWithoutChangingOriginal() async throws {
        let attempts = Mutex(0)
        let time = Mutex(ContinuousClock.now)
        let server = try await FakeServer { request in
            if request.path.hasSuffix("thumbnail-upload-token") {
                #expect(request.headers["authorization"] == "Bearer account-secret")
                return .json("{\"token\":\"thumbnail-only\"}")
            }
            #expect(request.method == "PUT" && request.path.hasSuffix("/thumbnail"))
            #expect(request.headers["authorization"] == "Bearer thumbnail-only")
            #expect(request.headers["content-type"] == "image/jpeg")
            #expect(request.body.prefix(2) == Data([0xff, 0xd8]))
            let count = attempts.withLock { $0 += 1; return $0 }
            return .init(status: count == 1 ? 500 : 204)
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "account-secret", secrets: secrets)
        let source = try #require(Bundle.module.url(forResource: "synthetic", withExtension: "heic", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: source)
        let staged = try store.stageFile(at: source)
        _ = try store.capture(text: "old HEIC", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
        try await store.pool.write { db in
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "UPDATE attachments SET uploaded = 1 WHERE id = ?", arguments: [staged.id])
        }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false, now: { time.withLock { $0 } })
        try await transfers.synchronize()
        #expect(attempts.withLock { $0 } == 1)
        #expect(try store.attachment(staged.id)?.hasThumbnail == false)
        #expect(try store.attachment(staged.id)?.uploaded == true)
        try await transfers.synchronize()
        #expect(attempts.withLock { $0 } == 1)
        time.withLock { $0 += .seconds(31) }
        try await transfers.synchronize()
        #expect(attempts.withLock { $0 } == 2)
        #expect(try store.attachment(staged.id)?.hasThumbnail == true)
        #expect(try Data(contentsOf: #require(try store.localFile(staged.id))) == original)
    }
}
