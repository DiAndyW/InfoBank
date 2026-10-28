import Foundation
import GRDB
import Testing
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
