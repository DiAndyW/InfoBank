import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct AttachmentCacheTests {
    @Test func lruProtectsPendingStagedAndPinnedFiles() throws {
        let (store, _) = try tempStore()
        let source = try AttachmentTests().source()
        let pending = try store.stageFile(at: source)
        _ = try store.capture(text: "", attachmentIDs: [pending.id], to: .inbox, nowUs: 1)
        let staged = try store.stageFile(at: source)
        let old = try store.stageFile(at: source)
        let pin = try store.stageFile(at: source)
        _ = try store.capture(text: "", attachmentIDs: [old.id, pin.id], to: .inbox, nowUs: 1)
        try store.pool.write { db in
            try db.execute(sql: "UPDATE attachments SET uploaded = 1 WHERE id IN (?, ?)", arguments: [old.id, pin.id])
        }
        try store.evictCache(nowUs: 100, maxFileBytes: 0, pinned: [pin.id])
        #expect(try store.localFile(old.id) == nil)
        #expect(try store.localFile(pin.id) != nil)
        #expect(try store.localFile(pending.id) != nil)
        #expect(try store.localFile(staged.id) != nil)
    }

    @Test func thumbnailsRetainedForRecentCaptureOrOpenAndMissingFilesRecover() throws {
        let (store, _) = try tempStore()
        let file = try store.stageFile(at: AttachmentTests().source())
        let item = try store.capture(text: "", attachmentIDs: [file.id], to: .inbox, nowUs: 1)
        let now: Int64 = 100 * 86_400_000_000
        let thumb = store.directory.appending(path: "thumb.jpg")
        try Data([1]).write(to: thumb)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO cached_files VALUES (?, 'thumbnail', 'thumb.jpg', 1, 1)", arguments: [file.id])
            try db.execute(sql: "UPDATE attachments SET uploaded = 1 WHERE id = ?", arguments: [file.id])
            try db.execute(sql: "UPDATE items SET opened_at = ? WHERE id = ?", arguments: [now, item])
        }
        try store.evictCache(nowUs: now)
        #expect(FileManager.default.fileExists(atPath: thumb.path))
        try store.evictCache(nowUs: now + 61 * 86_400_000_000)
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
        let local = try #require(try store.localFile(file.id))
        try FileManager.default.removeItem(at: local)
        #expect(try store.localFile(file.id) == nil)
    }
}

extension AttachmentCacheTests {
    @Test func anOlderPinnedFileCountsAgainstTheBudgetBeforeEvictableFiles() throws {
        let (store, _) = try tempStore()
        let source = try AttachmentTests().source()
        let pin = try store.stageFile(at: source)
        let old = try store.stageFile(at: source)
        let new = try store.stageFile(at: source)
        _ = try store.capture(text: "", attachmentIDs: [pin.id, old.id, new.id], to: .inbox, nowUs: 1)
        try store.pool.write { db in
            try db.execute(sql: "UPDATE attachments SET uploaded = 1")
            for (index, file) in [pin, old, new].enumerated() {
                try db.execute(sql: "UPDATE cached_files SET last_used_at = ? WHERE attachment_id = ?", arguments: [index, file.id])
            }
        }
        try store.evictCache(nowUs: 10, maxFileBytes: 10, pinned: [pin.id])
        #expect(try store.localFile(pin.id) != nil)
        #expect(try store.localFile(new.id) != nil)
        #expect(try store.localFile(old.id) == nil)
    }
}
