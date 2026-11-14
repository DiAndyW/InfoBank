import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct StoreTests {
    @Test func aNewStoreMigratesOnce() throws {
        let (store, file) = try tempStore()
        let applied = { (s: Store) in try s.pool.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") } }
        #expect(try applied(store) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"])
        #expect(try applied(Store(at: file, observesSuspension: false)) == ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"])
    }

    @Test func migrationRemovesArchiveColumnAndOnlyArchiveOps() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".db")
        let pool = try DatabasePool(path: file.path)
        try DatabaseMigrator.noteBank.migrate(pool, upTo: "v8")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO topics (id, name, archived_at) VALUES ('t', 'Old', 1);
                INSERT INTO outbox (op) VALUES ('{"type":"ArchiveTopic"}'), ('{"type":"UnarchiveTopic"}'), ('{"type":"CaptureItem"}');
                """)
        }
        try DatabaseMigrator.noteBank.migrate(pool)
        try pool.read { db throws -> Void in
            #expect(try db.columns(in: "topics").map(\.name).contains("archived_at") == false)
            #expect(try String.fetchAll(db, sql: "SELECT json_extract(op, '$.type') FROM outbox ORDER BY seq") == ["CaptureItem"])
            #expect(try String.fetchOne(db, sql: "SELECT name FROM topics WHERE id = 't'") == "Old")
        }
    }

    @Test func theDeviceIDIsCreatedOnceAndKept() throws {
        let (store, file) = try tempStore()
        let id = try store.deviceID()
        #expect(id.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
        #expect(try Store(at: file, observesSuspension: false).deviceID() == id)
    }

    @Test func emptyTextIsRejected() throws {
        let (store, _) = try tempStore()
        #expect(throws: DatabaseError.self) {
            try store.pool.write { try $0.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('a', '', 1)") }
        }
    }

    @Test func deletingAnItemDeletesItsAttachments() throws {
        let (store, _) = try tempStore()
        let left = try store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('a', 'hi', 1)")
            try db.execute(sql: "INSERT INTO attachments VALUES ('x', 'a', 'f.txt', 'text/plain', 3, 1, 0)")
            try db.execute(sql: "DELETE FROM items WHERE id = 'a'")
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments")
        }
        #expect(left == 0)
    }

    @Test func theMissingAppGroupErrorSaysWhy() {
        #expect(StoreError.noAppGroup.localizedDescription == "This app isn't set up to use its App Group container.")
    }

    @Test func thereIsOnlyOneDeviceRow() throws {
        let (store, _) = try tempStore()
        #expect(throws: DatabaseError.self) {
            try store.pool.write { try $0.execute(sql: "INSERT INTO device (id, device_id) VALUES (2, 'x')") }
        }
        #expect(throws: DatabaseError.self) {
            try store.pool.write { try $0.execute(sql: "INSERT INTO device (id, device_id) VALUES (1, 'x')") }
        }
    }

    @Test func theStoreDirectoryIsExcludedFromBackup() throws {
        let (_, file) = try tempStore()
        let values = try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func foreignKeysAreOn() throws {
        let (store, _) = try tempStore()
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") } == 1)
    }
}
