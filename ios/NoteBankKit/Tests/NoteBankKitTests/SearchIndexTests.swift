import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct SearchIndexTests {
    struct Entry: Equatable {
        var id: String
        var text: String
        var names: String
    }

    func indexed(_ store: Store) throws -> [Entry] {
        try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT coalesce(items.id, '?') AS id, search.text, search.names FROM search LEFT JOIN items ON items.rowid = search.rowid ORDER BY 1")
                .map { Entry(id: $0["id"], text: $0["text"], names: $0["names"]) }
        }
    }

    func addItem(_ store: Store, _ id: String, text: String?) throws {
        try store.pool.write { try $0.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES (?, ?, 1)", arguments: [id, text]) }
    }

    func addFile(_ store: Store, _ id: String, to item: String, named filename: String) throws {
        try store.pool.write {
            try $0.execute(
                sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?, ?, ?, 'x/y', 1, 1, 0)",
                arguments: [id, item, filename])
        }
    }

    @Test func migrationIndexesExistingItems() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "notebank.db")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: file.path)
        try DatabaseMigrator.noteBank.migrate(pool, upTo: "v6")
        try pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('1', 'hello', 1), ('2', NULL, 2)")
            try db.execute(sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES ('f', '2', 'a.pdf', 'application/pdf', 1, 1, 0)")
        }
        try pool.close()
        let store = try Store(at: file)
        #expect(try indexed(store) == [Entry(id: "1", text: "hello", names: ""), Entry(id: "2", text: "", names: "a.pdf")])
    }

    @Test func newAndChangedTextIsIndexed() throws {
        let (store, _) = try tempStore()
        let id = try store.capture(text: "first", to: .inbox, nowUs: 1)
        #expect(try indexed(store) == [Entry(id: id, text: "first", names: "")])
        let upsert = "INSERT INTO items (id, text, capture_time) VALUES (?, ?, 1) ON CONFLICT(id) DO UPDATE SET text = excluded.text"
        try store.pool.write { try $0.execute(sql: upsert, arguments: [id, "second"]) }
        #expect(try indexed(store) == [Entry(id: id, text: "second", names: "")])
        try store.pool.write { try $0.execute(sql: upsert, arguments: [id, "second"]) }
        #expect(try indexed(store) == [Entry(id: id, text: "second", names: "")])
    }

    @Test func filesFollowTheirItem() throws {
        let (store, _) = try tempStore()
        func fileNames() throws -> [String: [String]] {
            try indexed(store).reduce(into: [:]) { $0[$1.id] = $1.names.split(separator: "\n").sorted().map(String.init) }
        }
        try addItem(store, "a", text: "x")
        try addItem(store, "b", text: "y")
        try addFile(store, "f1", to: "a", named: "b.png")
        try addFile(store, "f2", to: "a", named: "a.pdf")
        #expect(try fileNames() == ["a": ["a.pdf", "b.png"], "b": []])
        try store.pool.write { try $0.execute(sql: "DELETE FROM attachments WHERE id = 'f1'") }
        #expect(try fileNames() == ["a": ["a.pdf"], "b": []])
        try store.pool.write { try $0.execute(sql: "UPDATE attachments SET item_id = 'b' WHERE id = 'f2'") }
        #expect(try fileNames() == ["a": [], "b": ["a.pdf"]])
    }

    @Test func aPullKeepsTheIndexCurrent() throws {
        let (store, _) = try tempStore()
        let serverURL = "http://127.0.0.1:9"
        try store.pool.write { try $0.execute(sql: "UPDATE device SET server_url = ?", arguments: [serverURL]) }
        func pull(_ items: [String] = [], tombstones: [String] = [], cursor: Int) throws {
            let json = """
                {"items":[\(items.joined(separator: ","))],"topics":[],"tombstones":[\(tombstones.map { "\"\($0)\"" }.joined(separator: ","))],
                 "cursor":\(cursor),"has_more":false,"settings":{"trash_after_copy":null}}
                """
            _ = try store.applyPull(JSONDecoder().decode(PullPage.self, from: Data(json.utf8)), serverURL: serverURL)
        }
        func item(_ text: String, files: [(id: String, name: String)]) -> String {
            let attachments = files.map {
                #"{"id":"\#($0.id)","filename":"\#($0.name)","mime_type":"image/png","size_bytes":10,"uploaded":true,"has_thumbnail":false}"#
            }
            return """
                {"id":"i","topic_id":null,"text":"\(text)","capture_time":"2025-10-09T08:53:20Z","deleted_at":null,"purge_at":null,
                 "text_rev":0,"tunnel":false,"attachments":[\(attachments.joined(separator: ","))]}
                """
        }
        func found(_ word: String) throws -> [String] { try store.search(SearchQuery(text: word), before: nil, limit: 10).map(\.id) }

        try pull([item("hello world", files: [("f1", "one.png"), ("f2", "two.png")])], cursor: 1)
        #expect(try indexed(store) == [Entry(id: "i", text: "hello world", names: "one.png\ntwo.png")])
        #expect(try found("hello") == ["i"])

        try pull([item("goodbye moon", files: [("f1", "one.png"), ("f2", "two.png")])], cursor: 2)
        #expect(try indexed(store) == [Entry(id: "i", text: "goodbye moon", names: "one.png\ntwo.png")])
        #expect(try found("goodbye") == ["i"])
        #expect(try found("hello").isEmpty)

        try pull([item("goodbye moon", files: [("f1", "one.png"), ("f2", "two.png")])], cursor: 3)
        #expect(try indexed(store) == [Entry(id: "i", text: "goodbye moon", names: "one.png\ntwo.png")])

        try pull([item("goodbye moon", files: [("f1", "uno.png")])], cursor: 4)
        #expect(try indexed(store) == [Entry(id: "i", text: "goodbye moon", names: "uno.png")])
        #expect(try found("uno") == ["i"])
        #expect(try found("two").isEmpty)

        try pull(tombstones: ["i"], cursor: 5)
        #expect(try indexed(store).isEmpty)
        #expect(try found("goodbye").isEmpty)
    }

    @Test func deletingAnItemLeavesNoOrphans() throws {
        let (store, _) = try tempStore()
        try addItem(store, "a", text: "x")
        try addFile(store, "f1", to: "a", named: "a.pdf")
        try addFile(store, "f2", to: "a", named: "b.png")
        try store.pool.write { try $0.execute(sql: "DELETE FROM items") }
        #expect(try indexed(store).isEmpty)
    }

    @Test func trashedItemsStayIndexed() throws {
        let (store, _) = try tempStore()
        try addItem(store, "a", text: "x")
        try store.pool.write { try $0.execute(sql: "UPDATE items SET deleted_at = 5, purge_at = 9 WHERE id = 'a'") }
        #expect(try indexed(store) == [Entry(id: "a", text: "x", names: "")])
    }

    @Test @MainActor func shareCaptureIsIndexed() throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let file = try store.stageFile(at: AttachmentTests().source(name: "shared.txt"))
        model.addAttachment(file)
        model.appendText("shared words")
        let id = try #require(model.save())
        #expect(try indexed(store) == [Entry(id: id, text: "shared words", names: "shared.txt")])
    }
}
