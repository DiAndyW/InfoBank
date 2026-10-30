import Foundation
import GRDB
import Testing
import Synchronization
@testable import NoteBankKit

struct AttachmentTransferTests {
    @Test func uploadWaitsForMetadataAcknowledgementAndOldServerCannotCompleteIt() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://example.com", newSecret: "secret", secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        #expect(try store.pendingUploads().isEmpty)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        #expect(try store.pendingUploads().map(\.id) == [file.id])
        try store.registerUpload(file.id, serverURL: "https://example.com", taskID: 4)
        try store.completeUpload(file.id, serverURL: "https://other.example", taskID: 4, status: 204, failed: false)
        #expect(try store.attachment(file.id)?.uploaded == false)
        try store.completeUpload(file.id, serverURL: "https://example.com", taskID: 3, status: 204, failed: false)
        #expect(try store.attachment(file.id)?.uploaded == false)
        try store.completeUpload(file.id, serverURL: "https://example.com", taskID: 4, status: 204, failed: false)
        #expect(try store.attachment(file.id)?.uploaded == true)
    }

    @Test func uploadFailureRetainsOriginalAndDoesNotMarkSynced() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://example.com", newSecret: "secret", secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        try store.registerUpload(file.id, serverURL: "https://example.com", taskID: 1)
        try store.completeUpload(file.id, serverURL: "https://example.com", taskID: 1, status: 401, failed: false)
        #expect(try store.attachment(file.id)?.uploaded == false)
        #expect(try store.localFile(file.id) != nil)
        #expect(try store.uploadError(file.id) != nil)
        #expect(try store.items(in: .all, before: nil, limit: 1).first?.attachments.first?.uploadError != nil)
    }

    @Test func captureUploadsWithScopedTokenAndSecondDeviceDownloadsExactBytes() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let staged = try store.stageFile(at: AttachmentTests().source())
        let item = try store.capture(text: "file", attachmentIDs: [staged.id], to: .inbox, nowUs: 1_760_000_000_000_000)
        var notices: [SyncNotice] = []
        _ = try await cycle(store: store, secrets: secrets, http: .live, queued: &notices)
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        try await transfers.synchronize()
        for _ in 0..<200 {
            if try store.attachment(staged.id)?.uploaded == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try store.attachment(staged.id)?.uploaded == true)
        let (other, _) = try tempStore(); let otherSecrets = SecretStore.memory()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: otherSecrets)
        _ = try await cycle(store: other, secrets: otherSecrets, http: .live, queued: &notices)
        #expect(try other.items(in: .inbox, before: nil, limit: 10).first?.id == item)
        let downloads = AttachmentTransfers(store: other, secrets: otherSecrets, background: false)
        let opened = try await downloads.open(staged.id)
        #expect(try Data(contentsOf: opened) == Data("hello".utf8))
        await downloads.release(staged.id)
    }
}

extension AttachmentTransferTests {
    @Test func downloadsCannotEscapePrivateAttachmentFolderOrCacheWrongSizedBodies() async throws {
        let server = try await FakeServer { _ in .init(body: Data("hello".utf8)) }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let item = try store.capture(text: "files", to: .inbox, nowUs: 1)
        let ids = (0..<3).map { _ in UUID().uuidString.lowercased() }
        try await store.pool.write { db in
            for (index, size) in [5, 4, 6].enumerated() {
                try db.execute(sql: "INSERT INTO attachments VALUES (?, ?, '../../outside.txt', 'text/plain', ?, 1, 0)", arguments: [ids[index], item, size])
            }
        }
        let downloads = AttachmentTransfers(store: store, secrets: secrets, background: false)
        let file = try await downloads.open(ids[0])
        #expect(file.standardizedFileURL.path.hasPrefix(store.directory.appending(path: "files/\(ids[0])/").path))
        await downloads.release(ids[0])
        for id in ids.dropFirst() {
            await #expect(throws: AttachmentError.self) { try await downloads.open(id) }
            #expect(try store.localFile(id) == nil)
        }
    }

    @Test func switchingServersAwayAndBackInvalidatesOldTaskCompletion() throws {
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://one.example", newSecret: "one", secrets: secrets)
        let staged = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "", attachmentIDs: [staged.id], to: .inbox, nowUs: 1)
        try store.registerUpload(staged.id, serverURL: "https://one.example", taskID: 7)
        try store.saveSettings(url: "https://two.example", newSecret: "two", secrets: secrets)
        try store.saveSettings(url: "https://one.example", newSecret: "one", secrets: secrets)
        try store.completeUpload(staged.id, serverURL: "https://one.example", taskID: 7, status: 204, failed: false)
        #expect(try store.attachment(staged.id)?.uploaded == false)
    }
}


extension AttachmentTransferTests {
    @Test func backgroundRequestUsesOnlyUploadCapabilityAndFailedUploadsWaitToRetry() async throws {
        let server = try await FakeServer { request in
            if request.path.hasSuffix("upload-token") {
                #expect(request.headers["authorization"] == "Bearer account-secret")
                return .json("{\"token\":\"attachment-only\"}")
            }
            #expect(request.headers["authorization"] == "Bearer attachment-only")
            #expect(request.body == Data("hello".utf8))
            return .init(status: 500)
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "account-secret", secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        try await store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        try await transfers.synchronize()
        for _ in 0..<100 {
            if try store.uploadError(file.id) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try store.uploadError(file.id) != nil)
        try? await transfers.synchronize()
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.requests(to: "/attachments/" + file.id) == 1)
        #expect(try store.attachment(file.id)?.uploaded == false)
    }
}

extension AttachmentTransferTests {
    @Test func redirectedSuccessDoesNotConfirmServerOwnershipOfTheOnlyLocalCopy() async throws {
        let destination = try await FakeServer { _ in .init(status: 204) }
        let server = try await FakeServer { request in
            if request.path.hasSuffix("upload-token") { return .json("{\"token\":\"attachment-only\"}") }
            return .init(status: 307, headers: ["Location": destination.url + "/elsewhere"])
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        try await store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        try await transfers.synchronize()
        for _ in 0..<100 {
            if try store.uploadError(file.id) != nil || store.attachment(file.id)?.uploaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try store.attachment(file.id)?.uploaded == false)
        try store.evictCache(nowUs: 100, maxFileBytes: 0)
        #expect(try store.localFile(file.id) != nil)
    }
}

extension AttachmentTransferTests {
    @Test func failedThumbnailBacksOffWithoutBlockingOtherThumbnailsAndRecovers() async throws {
        let bad = UUID().uuidString.lowercased(), good = UUID().uuidString.lowercased()
        let recovered = Mutex(false)
        let server = try await FakeServer { request in
            if request.path.contains(bad), !recovered.withLock({ $0 }) { return .init(status: 500) }
            return .init(body: Data("thumbnail".utf8))
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let item = try store.capture(text: "images", to: .inbox, nowUs: Time.nowUs())
        try await store.pool.write { db in
            for id in [bad, good] {
                try db.execute(sql: "INSERT INTO attachments VALUES (?, ?, 'image.png', 'image/png', 9, 1, 1)", arguments: [id, item])
            }
        }
        let time = Mutex(ContinuousClock.now)
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false, now: { time.withLock { $0 } })
        _ = try? await transfers.thumbnail(bad)
        await transfers.prefetchThumbnails()
        await transfers.prefetchThumbnails()
        #expect(server.requests(to: "/attachments/\(bad)/thumbnail") == 1)
        #expect(try store.localFile(good, kind: "thumbnail") != nil)
        time.withLock { $0 += .seconds(31) }
        _ = try? await transfers.thumbnail(bad)
        #expect(server.requests(to: "/attachments/\(bad)/thumbnail") == 2)
        recovered.withLock { $0 = true }
        time.withLock { $0 += .seconds(31) }
        _ = try? await transfers.thumbnail(bad)
        #expect(try store.localFile(bad, kind: "thumbnail") == nil)
        time.withLock { $0 += .seconds(30) }
        await transfers.prefetchThumbnails()
        #expect(try store.localFile(bad, kind: "thumbnail") != nil)
        #expect(server.requests(to: "/attachments/\(bad)/thumbnail") == 3)
    }

    @Test func thumbnailFailureDoesNotThrottleAnotherServerGeneration() async throws {
        let server = try await FakeServer { _ in .init(status: 500) }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let item = try store.capture(text: "image", to: .inbox, nowUs: Time.nowUs())
        let id = UUID().uuidString.lowercased()
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO attachments VALUES (?, ?, 'image.png', 'image/png', 9, 1, 1)", arguments: [id, item])
        }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        _ = try? await transfers.thumbnail(id)
        _ = try? await transfers.thumbnail(id)
        #expect(server.requests(to: "/attachments/\(id)/thumbnail") == 1)
        try await store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        try store.saveSettings(url: "http://localhost:1", newSecret: "other", secrets: secrets)
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time, text_rev, topic_id, deleted_at, in_tunnel, opened_at) VALUES (?, 'image', ?, 1, NULL, NULL, 0, 0)", arguments: [item, Time.nowUs()])
            try db.execute(sql: "INSERT INTO attachments VALUES (?, ?, 'image.png', 'image/png', 9, 1, 1)", arguments: [id, item])
        }
        _ = try? await transfers.thumbnail(id)
        #expect(server.requests(to: "/attachments/\(id)/thumbnail") == 2)
    }
}

extension AttachmentTransferTests {
    @Test func concurrentThumbnailCallersBothReceiveTheDownloadedFile() async throws {
        let server = try await FakeServer { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .init(body: Data("thumbnail".utf8))
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let item = try store.capture(text: "image", to: .inbox, nowUs: Time.nowUs())
        let id = UUID().uuidString.lowercased()
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO attachments VALUES (?, ?, 'image.png', 'image/png', 9, 1, 1)", arguments: [id, item])
        }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        async let first = transfers.thumbnail(id)
        async let second = transfers.thumbnail(id)
        let results = try await (first, second)
        #expect(results.0 != nil)
        #expect(results.1 != nil)
        #expect(results.0 == results.1)
        #expect(server.requests(to: "/attachments/\(id)/thumbnail") == 1)
    }
}

extension AttachmentTransferTests {
    @Test func prefetchContinuesAfterItsFirstThumbnailFails() async throws {
        let first = Mutex(true)
        let server = try await FakeServer { _ in
            if first.withLock({ state in let wasFirst = state; state = false; return wasFirst }) { return .init(status: 500) }
            return .init(body: Data("thumbnail".utf8))
        }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let item = try store.capture(text: "images", to: .inbox, nowUs: Time.nowUs())
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
        try await store.pool.write { db in
            for id in ids {
                try db.execute(sql: "INSERT INTO attachments VALUES (?, ?, 'image.png', 'image/png', 9, 1, 1)", arguments: [id, item])
            }
        }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        await transfers.prefetchThumbnails()
        let cached = try ids.filter { try store.localFile($0, kind: "thumbnail") != nil }
        #expect(cached.count == 1)
        #expect(ids.reduce(0) { $0 + server.requests(to: "/attachments/\($1)/thumbnail") } == 2)
    }
}

extension AttachmentTransferTests {
    @Test func otherSessionsCannotCompleteOrReplaceAnActiveUpload() throws {
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://example.com", newSecret: "secret", secrets: secrets)
        let file = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        try store.registerUpload(file.id, serverURL: "https://example.com", taskID: 1, sessionIdentifier: AttachmentTransfers.shareSessionIdentifier)
        #expect(try !store.canScheduleUpload(file.id, sessionIdentifier: AttachmentTransfers.sessionIdentifier))
        #expect(throws: AttachmentError.self) {
            try store.registerUpload(file.id, serverURL: "https://example.com", taskID: 1)
        }
        try store.completeUpload(file.id, serverURL: "https://example.com", taskID: 1, status: 204, failed: false)
        #expect(try store.attachment(file.id)?.uploaded == false)
        try store.completeUpload(file.id, serverURL: "https://example.com", taskID: 1, status: 500, failed: false, sessionIdentifier: AttachmentTransfers.shareSessionIdentifier)
        #expect(try store.canScheduleUpload(file.id, sessionIdentifier: AttachmentTransfers.sessionIdentifier))
    }
}

extension AttachmentTransferTests {
    @Test func clipboardExportsSurviveOriginalRemovalAndKeepDuplicateNames() async throws {
        let (store, _) = try tempStore()
        let first = try store.stageFile(at: AttachmentTests().source())
        let second = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "", attachmentIDs: [first.id, second.id], to: .tunnel, nowUs: 1)
        let transfers = AttachmentTransfers(store: store, secrets: .memory(), background: false)
        let files = try await transfers.clipboardFiles([first.id, second.id])
        #expect(files.count == 2)
        #expect(files[0] != files[1])
        try FileManager.default.removeItem(at: store.directory.appending(path: "files"))
        for file in files { #expect(try Data(contentsOf: file) == Data("hello".utf8)) }
    }

    @Test func clipboardExportFailureRetainsItemAndRemovesPartialExports() async throws {
        let (store, _) = try tempStore()
        let staged = try store.stageFile(at: AttachmentTests().source())
        let item = try store.capture(text: "keep me", attachmentIDs: [staged.id], to: .tunnel, nowUs: 1)
        let transfers = AttachmentTransfers(store: store, secrets: .memory(), background: false)
        await #expect(throws: AttachmentError.self) { try await transfers.clipboardFiles([staged.id, UUID().uuidString.lowercased()]) }
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).first?.id == item)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.appending(path: "clipboard").path).isEmpty)
    }
}
