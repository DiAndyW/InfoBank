import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct PullTests {
    static let serverURL = "http://127.0.0.1:9"

    private func configuredStore() throws -> Store {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "UPDATE device SET server_url = ?", arguments: [Self.serverURL]) }
        return store
    }

    private func page(_ json: String) throws -> PullPage {
        try JSONDecoder().decode(PullPage.self, from: Data(json.utf8))
    }

    private func attachment(_ id: String) -> String {
        #"{"id":"\#(id)","filename":"\#(id).png","mime_type":"image/png","size_bytes":10,"uploaded":true,"has_thumbnail":false}"#
    }

    private func item(_ id: String, _ text: String, textRev: Int = 0, attachments: [String] = []) -> String {
        """
        {"id":"\(id)","topic_id":null,"text":"\(text)","capture_time":"2025-10-09T08:53:20.123456Z",
         "deleted_at":null,"purge_at":null,"text_rev":\(textRev),"tunnel":false,"attachments":[\(attachments.map(attachment).joined(separator: ","))]}
        """
    }

    private func pageJSON(items: [String] = [], topics: [String] = [], tombstones: [String] = [], trashAfterCopy: String = "null", cursor: Int) -> String {
        """
        {"items":[\(items.joined(separator: ","))],"topics":[\(topics.joined(separator: ","))],
         "tombstones":[\(tombstones.map { "\"\($0)\"" }.joined(separator: ","))],"cursor":\(cursor),"has_more":false,"settings":{"trash_after_copy":\(trashAfterCopy)}}
        """
    }

    private func cursor(_ store: Store) throws -> Int64 {
        try store.pool.read { try Int64.fetchOne($0, sql: "SELECT pull_cursor FROM device")! }
    }

    private func attachmentIDs(_ store: Store) throws -> [String] {
        try store.pool.read { try String.fetchAll($0, sql: "SELECT id FROM attachments ORDER BY id") }
    }

    private func snapshot(_ store: Store) throws -> [String] {
        try store.pool.read { db in
            try ["items", "topics", "attachments", "device"].flatMap { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1").map { "\(table): \($0)" }
            }
        }
    }

    @Test func aPullDoesNotOverwriteAQueuedSetTrashAfterCopy() throws {
        let store = try configuredStore()
        try store.setTrashAfterCopy(true, nowUs: 1_760_000_000_000_000)
        _ = try store.applyPull(try page(pageJSON(trashAfterCopy: "false", cursor: 1)), serverURL: Self.serverURL)
        #expect(try store.trashAfterCopy() == true)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        #expect(try store.trashAfterCopy() == true)
        _ = try store.applyPull(try page(pageJSON(trashAfterCopy: "false", cursor: 2)), serverURL: Self.serverURL)
        #expect(try store.trashAfterCopy() == false)
        _ = try store.applyPull(try page(pageJSON(cursor: 3)), serverURL: Self.serverURL)
        #expect(try store.trashAfterCopy() == nil)
    }

    @Test func aPullKeepsTheTrashStateOfAnItemWithAQueuedTrashOrRestore() throws {
        let store = try configuredStore()
        let trashed = item("t", "trashed").replacingOccurrences(of: #""deleted_at":null,"purge_at":null"#, with: #""deleted_at":"2025-10-09T08:53:20Z","purge_at":"2025-11-08T08:53:20Z""#)
        _ = try store.applyPull(try page(pageJSON(items: [item("a", "live"), trashed], cursor: 1)), serverURL: Self.serverURL)
        try store.trash(itemID: "a", nowUs: 1_760_000_000_000_000)
        try store.restore(itemID: "t", nowUs: 1_760_000_000_000_000)
        _ = try store.applyPull(try page(pageJSON(items: [item("a", "live"), trashed], cursor: 2)), serverURL: Self.serverURL)
        let state = { (id: String) in try store.pool.read { try Bool.fetchOne($0, sql: "SELECT deleted_at IS NOT NULL FROM items WHERE id = ?", arguments: [id])! } }
        #expect(try state("a") == true)
        #expect(try state("t") == false)

        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        _ = try store.applyPull(try page(pageJSON(items: [item("a", "live"), trashed], cursor: 3)), serverURL: Self.serverURL)
        #expect(try state("a") == false)
        #expect(try state("t") == true)
    }

    @Test func pullSetsAndClearsTheTunnelFlag() throws {
        let store = try configuredStore()
        let tunnelItem = item("i", "hi").replacingOccurrences(of: #""tunnel":false"#, with: #""tunnel":true"#)
        _ = try store.applyPull(try page(pageJSON(items: [tunnelItem], cursor: 1)), serverURL: Self.serverURL)
        let flag = { try store.pool.read { try Int.fetchOne($0, sql: "SELECT in_tunnel FROM items WHERE id = 'i'")! } }
        #expect(try flag() == 1)
        _ = try store.applyPull(try page(pageJSON(items: [item("i", "hi")], cursor: 2)), serverURL: Self.serverURL)
        #expect(try flag() == 0)
    }

    @Test func aPageIsStoredWithItsCursorAndTextRev() throws {
        let store = try configuredStore()
        let trashed = #"{"id":"j","topic_id":"t","text":null,"capture_time":"2025-10-09T08:53:21+00:00","deleted_at":"2025-10-10T00:00:00Z","purge_at":"2025-11-09T00:00:00.5Z","text_rev":2,"tunnel":false,"attachments":[]}"#
        let topic = #"{"id":"t","name":"Mosaic","archived_at":"2025-10-09T08:53:20.000001Z","deleted_at":null}"#
        let p = try page(pageJSON(items: [item("i", "hello", textRev: 7, attachments: ["a"]), trashed], topics: [topic], cursor: 7))

        #expect(try store.applyPull(p, serverURL: Self.serverURL))

        let (row, trashedRow, topicRow) = try store.pool.read { db in
            (
                try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = 'i'")!,
                try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = 'j'")!,
                try Row.fetchOne(db, sql: "SELECT * FROM topics")!
            )
        }
        #expect(row["text"] as String == "hello")
        #expect(row["capture_time"] as Int64 == 1_760_000_000_123_456)
        #expect(row["text_rev"] as Int64 == 7)
        #expect(trashedRow["text"] as String? == nil)
        #expect(trashedRow["topic_id"] as String == "t")
        #expect(trashedRow["deleted_at"] as Int64 == 1_760_054_400_000_000)
        #expect(trashedRow["purge_at"] as Int64 == 1_762_646_400_500_000)
        #expect(topicRow["name"] as String == "Mosaic")
        #expect(topicRow["archived_at"] as Int64 == 1_760_000_000_000_001)
        #expect(topicRow["deleted_at"] as Int64? == nil)
        #expect(try attachmentIDs(store) == ["a"])
        #expect(try cursor(store) == 7)
    }

    @Test func aLaterVersionReplacesTextAndTheAttachmentSet() throws {
        let store = try configuredStore()
        _ = try store.applyPull(page(pageJSON(items: [item("i", "v1", attachments: ["a0", "a1"])], cursor: 1)), serverURL: Self.serverURL)
        _ = try store.applyPull(page(pageJSON(items: [item("i", "v2", textRev: 1, attachments: ["a1", "a2"])], cursor: 2)), serverURL: Self.serverURL)

        let text = try store.pool.read { try String.fetchOne($0, sql: "SELECT text FROM items")! }
        #expect(text == "v2")
        #expect(try attachmentIDs(store) == ["a1", "a2"])
    }

    @Test func aTombstoneDeletesTheItemAndItsAttachments() throws {
        let store = try configuredStore()
        _ = try store.applyPull(page(pageJSON(items: [item("i", "x", attachments: ["a"])], cursor: 1)), serverURL: Self.serverURL)
        #expect(try store.applyPull(page(pageJSON(tombstones: ["i"], cursor: 2)), serverURL: Self.serverURL))

        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM items")! } == 0)
        #expect(try attachmentIDs(store).isEmpty)
    }

    @Test func anEmptyPageChangesNothingButTheCursor() throws {
        let store = try configuredStore()
        _ = try store.applyPull(page(pageJSON(items: [item("i", "x")], cursor: 1)), serverURL: Self.serverURL)
        let before = try snapshot(store)

        #expect(try !store.applyPull(page(pageJSON(cursor: 3)), serverURL: Self.serverURL))

        #expect(try cursor(store) == 3)
        #expect(try snapshot(store).filter { !$0.hasPrefix("device") } == before.filter { !$0.hasPrefix("device") })
    }

    @Test func rerunningAPageIsANoOp() throws {
        let store = try configuredStore()
        let p = try page(pageJSON(
            items: [item("i", "v", textRev: 3, attachments: ["a", "b"])],
            topics: [#"{"id":"t","name":"Gym","archived_at":null,"deleted_at":null}"#],
            cursor: 4))
        _ = try store.applyPull(p, serverURL: Self.serverURL)
        let once = try snapshot(store)

        _ = try store.applyPull(p, serverURL: Self.serverURL)

        #expect(try snapshot(store) == once)
    }

    @Test func pullClearsASyncError() throws {
        let store = try configuredStore()
        try store.pool.write {
            try $0.execute(sql: "INSERT INTO items (id, text, capture_time, sync_error) VALUES ('i', 'x', 1, 'exists')")
        }

        _ = try store.applyPull(page(pageJSON(items: [item("i", "x", textRev: 7)], cursor: 1)), serverURL: Self.serverURL)

        let (rev, error) = try store.pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT text_rev, sync_error FROM items WHERE id = 'i'")!
            return (row["text_rev"] as Int64, row["sync_error"] as String?)
        }
        #expect(rev == 7)
        #expect(error == nil)
    }

    @Test func aPageForAnotherServerWritesNothing() throws {
        let store = try configuredStore()
        _ = try store.applyPull(page(pageJSON(items: [item("i", "x")], cursor: 1)), serverURL: Self.serverURL)
        let before = try snapshot(store)

        let other = try page(pageJSON(
            items: [item("i", "changed"), item("k", "new")],
            topics: [#"{"id":"t","name":"Gym","archived_at":null,"deleted_at":null}"#],
            tombstones: ["i"], cursor: 9))
        #expect(try !store.applyPull(other, serverURL: "http://127.0.0.1:10"))

        #expect(try snapshot(store) == before)
        #expect(try cursor(store) == 1)
    }

    @Test func aPageWithAnUnreadableTimeFailsToDecode() {
        let bad = item("i", "x").replacingOccurrences(of: "2025-10-09T08:53:20.123456Z", with: "yesterday")
        #expect(throws: DecodingError.self) { try page(pageJSON(items: [bad], cursor: 1)) }
    }

    @Test func labelIsOneShortLineOrTheFirstFilename() {
        let long = "first   line\n" + String(repeating: "x", count: 60) + "\nsecond"
        #expect(label(text: long, firstFilename: "scan.png") == "first line " + String(repeating: "x", count: 29) + "…")
        #expect(label(text: String(repeating: "y", count: 40), firstFilename: nil) == String(repeating: "y", count: 40))
        #expect(label(text: "  \n ", firstFilename: "scan.png") == "scan.png")
        #expect(label(text: nil, firstFilename: "scan.png") == "scan.png")
        #expect(label(text: nil, firstFilename: nil) == "")
    }

    @Test func noticeMessages() {
        func notice(_ name: String?, _ state: SyncNotice.TopicState?) -> String {
            SyncNotice(itemID: "i", label: "squat 100", topicName: name, topicID: nil, topicState: state).message
        }
        #expect(notice("Gym", .archived) == #"Saved "squat 100" to the Inbox: Gym was archived on another Device."#)
        #expect(notice("Gym", .deleted) == #"Saved "squat 100" to the Inbox: Gym was deleted on another Device."#)
        #expect(notice(nil, nil) == #"Saved "squat 100" to the Inbox: its Topic isn't on this Server."#)
    }
}
