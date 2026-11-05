import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct BatchActionsTests {
    @Test func copySnapshotPreservesRequestedOrderAndRefusesMissingOrTrashedItems() throws {
        let store = try tempStore().store
        let a = try store.capture(text: "first", to: .inbox, nowUs: 1)
        let b = try store.capture(text: "second", to: .tunnel, nowUs: 2)
        let items = try store.items(ids: [b, a])
        #expect(items.map(\.id) == [b, a])
        #expect(ItemClipboard.text(items: items) == "second\n\nfirst")
        #expect(throws: ItemActionError.notFound) { try store.items(ids: [a, "missing"]) }
        try store.trash(itemID: b, nowUs: 3)
        #expect(throws: ItemActionError.notFound) { try store.items(ids: [a, b]) }
    }

    @Test func batchTrashAndRestoreQueueEachItemOnceAndRollbackFailures() throws {
        let store = try tempStore().store
        let a = try store.capture(text: "first", to: .tunnel, nowUs: 1)
        let b = try store.capture(text: "second", to: .tunnel, nowUs: 2)
        try store.pool.write { try $0.execute(sql: "DELETE FROM outbox") }
        #expect(throws: ItemActionError.notFound) { try store.trash(itemIDs: [a, "missing"], nowUs: 3) }
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).count == 2)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 0)
        try store.trash(itemIDs: [a, b, a], nowUs: 3)
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).isEmpty)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 2)
        #expect(throws: ItemActionError.notFound) { try store.restore(itemIDs: [a, "missing"], nowUs: 4) }
        #expect(try store.items(in: .trash, before: nil, limit: 10).count == 2)
        try store.restore(itemIDs: [a, b], nowUs: 4)
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).count == 2)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM outbox") } == 4)
    }

    @Test func batchRefusesRejectedChangedAndExpiredItems() throws {
        let store = try tempStore().store
        let a = try store.capture(text: "first", to: .inbox, nowUs: 1)
        let b = try store.capture(text: "second", to: .inbox, nowUs: 2)
        try store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = 'invalid' WHERE id = ?", arguments: [b]) }
        #expect(throws: ItemActionError.notFound) { try store.trash(itemIDs: [a, b], nowUs: 3) }
        #expect(try store.items(in: .inbox, before: nil, limit: 10).count == 2)
        try store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = NULL, deleted_at = 2, purge_at = 3 WHERE id = ?", arguments: [b]) }
        #expect(throws: ItemActionError.notFound) { try store.trash(itemIDs: [a, b], nowUs: 4) }
        #expect(throws: ItemActionError.notFound) { try store.restore(itemIDs: [b], nowUs: 4) }
        try store.pool.write { try $0.execute(sql: "UPDATE items SET text = NULL, purge_at = NULL WHERE id = ?", arguments: [b]) }
        #expect(throws: ItemActionError.notFound) { try store.restore(itemIDs: [b], nowUs: 4) }
    }
}
