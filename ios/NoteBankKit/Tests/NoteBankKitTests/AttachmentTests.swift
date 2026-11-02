import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct AttachmentTests {
    func source(_ data: Data = Data("hello".utf8), name: String = "test.txt") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try data.write(to: file)
        return file
    }

    @Test func attachmentOnlyCaptureOwnsDurableFilesAndPushMetadata() throws {
        let (store, _) = try tempStore()
        let staged = try store.stageFile(at: source(), filename: "../a.txt")
        #expect(!staged.filename.contains("/"))
        let item = try store.capture(text: "", attachmentIDs: [staged.id], to: .tunnel, nowUs: 1)
        let feed = try #require(try store.items(in: .tunnel, before: nil, limit: 10).first)
        #expect(feed.id == item && feed.text == nil)
        #expect(feed.attachmentNames == [staged.filename])
        #expect(try Data(contentsOf: store.localFile(staged.id)!) == Data("hello".utf8))
        let op = try store.pool.read { try String.fetchOne($0, sql: "SELECT op FROM outbox")! }
        let json = try #require(JSONSerialization.jsonObject(with: Data(op.utf8)) as? [String: Any])
        #expect(json["text"] is NSNull)
        #expect((json["attachments"] as? [[String: Any]])?.first?["id"] as? String == staged.id)
        #expect(throws: (any Error).self) { try store.capture(text: "again", attachmentIDs: [staged.id], to: .inbox, nowUs: 2) }
    }

    @Test func failedCaptureRetainsStagedFilesAndRollsBackAllWrites() throws {
        let (store, _) = try tempStore()
        let staged = try store.stageFile(at: source())
        try store.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'fail'); END") }
        #expect(throws: (any Error).self) { try store.capture(text: "x", attachmentIDs: [staged.id], to: .inbox, nowUs: 1) }
        #expect(try store.localFile(staged.id) != nil)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items") } == 0)
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER refuse") }
        _ = try store.capture(text: "", attachmentIDs: [staged.id], to: .inbox, nowUs: 1)
    }

    @Test func oversizedOrMissingFilesAreNotStaged() throws {
        let (store, _) = try tempStore()
        let file = try source(Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(100 << 20) + 1)
        try handle.close()
        #expect(throws: (any Error).self) { try store.stageFile(at: file) }
        #expect(throws: (any Error).self) { try store.stageFile(at: file.appending(path: "missing")) }
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM staged_files") } == 0)
    }

    @Test @MainActor func composerSendsFilesWithoutTextAndRetainsThemAfterFailure() throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        let file = try store.stageFile(at: source())
        model.addAttachments([file])
        #expect(model.canSend)
        try store.pool.write { try $0.execute(sql: "CREATE TRIGGER refuse BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT, 'fail'); END") }
        #expect(!model.send())
        #expect(model.attachments == [file])
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER refuse") }
        #expect(model.send())
        #expect(model.attachments.isEmpty && !model.canSend)
    }
}

extension AttachmentTests {
    @Test func importedNamesFitServerUTF8LimitAndRelaunchCleansOnlyAbandonedFiles() throws {
        let database = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/notebank.db")
        let ids = try { () -> (String, String) in
            let store = try Store(at: database, observesSuspension: false)
            let staged = try store.stageFile(at: source(), filename: String(repeating: "🌱", count: 100) + ".txt")
            #expect(staged.filename.utf8.count <= 255)
            #expect(staged.filename.hasSuffix(".txt"))
            let kept = try store.stageFile(at: source())
            _ = try store.capture(text: "", attachmentIDs: [kept.id], to: .inbox, nowUs: 1)
            return (staged.id, kept.id)
        }()
        let relaunched = try Store(at: database, observesSuspension: false)
        #expect(try relaunched.localFile(ids.0) == nil)
        #expect(try relaunched.localFile(ids.1) != nil)
    }
}

extension AttachmentTests {
    @Test @MainActor func sendingWaitsUntilSelectedFilesFinishImporting() throws {
        let (store, _) = try tempStore()
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        model.text = "keep the photo with this"
        model.beginImport()
        #expect(!model.canSend)
        #expect(!model.send())
        #expect(try store.items(in: .all, before: nil, limit: 10).isEmpty)
        model.endImport()
        #expect(model.send())
    }
}

extension AttachmentTests {
    @Test func openingAnotherStorePreservesLiveDraftAndDownload() throws {
        let (store, database) = try tempStore()
        let staged = try store.stageFile(at: source())
        let download = store.directory.appending(path: ".dl-active")
        try Data("partial".utf8).write(to: download)
        let other = try Store(at: database, observesSuspension: false)
        #expect(try other.localFile(staged.id) != nil)
        #expect(FileManager.default.fileExists(atPath: download.path))
        _ = try store.capture(text: "", attachmentIDs: [staged.id], to: .inbox, nowUs: 1)
    }
}

extension AttachmentTests {
    @Test func deadStoreRegistrationDoesNotKeepAbandonedFilesForever() throws {
        let database = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/notebank.db")
        let id = try { () -> String in
            let store = try Store(at: database, observesSuspension: false)
            let file = try store.stageFile(at: source())
            try store.pool.write { try $0.execute(sql: "INSERT INTO file_sessions VALUES ('terminated-process', 2147483647)") }
            return file.id
        }()
        let store = try Store(at: database, observesSuspension: false)
        #expect(try store.localFile(id) == nil)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM file_sessions WHERE id = 'terminated-process'") } == 0)
    }
}
