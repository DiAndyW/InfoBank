import Foundation
import Testing
@testable import NoteBankKit

@MainActor struct BehaviourTests {
    private func check(_ center: NoticeCenter, _ expected: Behaviour.Expectation, values: [String: String] = [:]) {
        #expect(center.current?.message == expected.message(values))
        #expect((center.current?.actionTitle.map { [$0] } ?? []) + ["close"] == expected.buttons)
    }

    @Test func notices() throws {
        let center = NoticeCenter()
        center.postCopiedText()
        check(center, try Behaviour.rule("notice.copied_text"))
        center.postTrashed(itemID: "a", copied: false)
        check(center, try Behaviour.rule("notice.trashed"))
        center.postTrashed(itemID: "a")
        check(center, try Behaviour.rule("notice.copied_trashed"))
        center.postCleared(.inbox)
        check(center, try Behaviour.rule("notice.cleared"))
        for count in [1, 2] {
            let ids = Array(["a", "b"].prefix(count))
            let values = ["count": String(count), "items": count == 1 ? "Item" : "Items"]
            center.postBatchCompleted(count: count, copied: true)
            check(center, try Behaviour.rule("notice.batch_copied"), values: values)
            center.postBatchCompleted(count: count, copied: false)
            check(center, try Behaviour.rule("notice.batch_restored"), values: values)
            center.postTrashed(itemIDs: ids, copied: false)
            check(center, try Behaviour.rule("notice.batch_trashed"), values: values)
            center.postTrashed(itemIDs: ids, copied: true)
            check(center, try Behaviour.rule("notice.batch_copied_trashed"), values: values)
        }
        center.post([SyncNotice(itemID: "a", label: "note", topicName: "Gym", topicID: "g", topicState: .archived)])
        check(center, try Behaviour.rule("notice.sync_inbox_archived"), values: ["label": "note", "topic": "Gym"])
        center.post([SyncNotice(itemID: "a", label: "note", topicName: "Gym", topicID: "g", topicState: .deleted)])
        check(center, try Behaviour.rule("notice.sync_inbox_deleted"), values: ["label": "note", "topic": "Gym"])
        let last = SyncNotice(itemID: "a", label: "note", topicName: "Gym", topicID: "g", topicState: .archived)
        center.post([last, last])
        check(center, try Behaviour.rule("notice.sync_inbox_more"), values: ["label": "note", "topic": "Gym", "count": "1"])
    }

    @Test func duration() throws {
        #expect(Notice.durationSeconds == (try Behaviour.rule("notice.duration")).duration_seconds)
    }

    private func checkCopy(_ expected: Behaviour.Expectation, place: Place, trashAfterCopy: Bool? = false) {
        let actions = CopyActions(place: place, hasText: true, trashAfterCopy: trashAfterCopy)
        #expect(actions.menu.map { Behaviour.Action(id: $0.kind.rawValue, label: $0.label) } == expected.menu)
        #expect(actions.row == expected.row)
        #expect(actions.batch.map { Behaviour.Action(id: $0.kind.rawValue, label: $0.label) } == expected.batch)
    }

    @Test func copyPlaces() throws {
        checkCopy(try Behaviour.rule("copy.inbox"), place: .inbox)
        checkCopy(try Behaviour.rule("copy.topic"), place: .topic("g"))
        checkCopy(try Behaviour.rule("copy.archived_topic"), place: .topic("archived"))
        for preference in [false, nil] {
            checkCopy(try Behaviour.rule("copy.tunnel"), place: .tunnel, trashAfterCopy: preference)
        }
        checkCopy(try Behaviour.rule("copy.tunnel_trash"), place: .tunnel, trashAfterCopy: true)
        checkCopy(try Behaviour.rule("copy.trash"), place: .trash)
        checkCopy(try Behaviour.rule("copy.search"), place: .all)
    }

    @Test func copyWithoutText() throws {
        let expected = try Behaviour.rule("copy.without_text")
        for place in [Place.inbox, .topic("g"), .tunnel, .trash, .all] {
            #expect(CopyActions(place: place, hasText: false).menu.contains { $0.kind == .text } == expected.offered)
        }
    }

    @Test func attachmentCopy() throws {
        let expected = try Behaviour.rule("copy.single_attachment")
        #expect(!CopyActions(place: .inbox, hasText: true).attachment.isEmpty == expected.offered)
        #expect(CopyActions.copyLabel == expected.label)
    }
}


extension BehaviourTests {
    @Test func destinationNotices() throws {
        let store = try tempStore().store
        let topic = try store.pickerTopic(named: "Gym", nowUs: 1)
        let item = try store.capture(text: "note", to: .inbox, nowUs: 2)
        let center = NoticeCenter()
        for (destination, expected) in [(Destination.tunnel, try Behaviour.rule("notice.moved_tunnel")), (.inbox, try Behaviour.rule("notice.moved_inbox")), (.topic(topic), try Behaviour.rule("notice.moved_topic"))] {
            try store.move(itemID: item, to: destination, nowUs: 3)
            try center.postMoved(itemID: item, from: .inbox, store: store)
            check(center, expected, values: ["topic": "Gym"])
            #expect(center.current?.action == .undoMove(.inbox))
        }
        for destination in [Destination.tunnel, .inbox, .topic(topic)] {
            try store.move(itemID: item, to: destination, nowUs: 4)
            try store.trash(itemID: item, nowUs: 5)
            try store.restore(itemID: item, nowUs: 6)
            try center.postRestored(itemID: item, store: store)
            check(center, try Behaviour.rule("notice.restored"), values: ["destination": destination == .tunnel ? "Tunnel" : destination == .inbox ? "Inbox" : "Gym"])
        }
    }

    @Test func additionalSyncNotices() throws {
        let center = NoticeCenter()
        func sync(_ expected: Behaviour.Expectation, kind: SyncNotice.Kind, topic: String? = nil, item: String = "a", state: SyncNotice.TopicState? = nil) {
            var notice = SyncNotice(itemID: item, label: "note", topicName: topic, topicID: nil, topicState: state)
            notice.kind = kind
            center.post([notice])
            check(center, expected, values: ["label": "note", "topic": "Gym", "state": state?.rawValue ?? "archived or deleted"])
        }
        for state in [SyncNotice.TopicState.archived, .deleted, nil] {
            sync(try Behaviour.rule("notice.sync_move"), kind: .move, topic: "Gym", state: state)
        }
        sync(try Behaviour.rule("notice.sync_empty"), kind: .empty)
        sync(try Behaviour.rule("notice.sync_gone"), kind: .gone)
        sync(try Behaviour.rule("notice.sync_inbox_unknown"), kind: .inbox)
        sync(try Behaviour.rule("notice.sync_inbox_state_unknown"), kind: .inbox, topic: "Gym")
        sync(try Behaviour.rule("notice.sync_failed"), kind: .failed)
        sync(try Behaviour.rule("notice.sync_failed_without_item"), kind: .failed, item: "")
        sync(try Behaviour.rule("notice.sync_topic"), kind: .topic, item: "")
        sync(try Behaviour.rule("notice.sync_topic_renamed"), kind: .topicRenamed, item: "")
    }

    @Test func topicDeletionNotices() throws {
        for count in [0, 1, 2] {
            for keep in [TopicKeep.all, .none, .only([])] {
                let store = try tempStore().store
                let topic = try store.createTopic(name: "Gym", nowUs: 1)
                var ids: [String] = []
                for index in 0..<count { ids.append(try store.capture(text: "note \(index)", to: .topic(topic), nowUs: 2)) }
                let selected = Set(ids.prefix(1))
                let choice: TopicKeep = if case .only = keep { .only(selected) } else { keep }
                let expected: Behaviour.Expectation
                let kept: Int
                if count == 0 { expected = try Behaviour.rule("notice.topic_deleted_empty"); kept = 0 }
                else { switch keep {
                case .all: expected = try Behaviour.rule("notice.topic_deleted_all"); kept = count
                case .none: expected = try Behaviour.rule("notice.topic_deleted_none"); kept = 0
                case .only: expected = try Behaviour.rule("notice.topic_deleted_selected"); kept = selected.count
                } }
                let result = try store.deleteTopic(topic, keeping: choice, nowUs: 3)
                let center = NoticeCenter()
                center.postTopicDeleted(result)
                let number = if case .only = keep { kept } else { count }
                #expect(result == expected.message(["topic": "Gym", "count": String(number), "items": number == 1 ? "Item" : "Items", "trashed": String(count - kept)]))
                check(center, expected, values: ["topic": "Gym", "count": String(number), "items": number == 1 ? "Item" : "Items", "trashed": String(count - kept)])
                #expect(try store.items(in: .inbox, before: nil, limit: 10).count == kept)
                #expect(try store.items(in: .trash, before: nil, limit: 10).count == count - kept)
            }
        }
    }

    @Test func attachmentNoticeIsNotOfferedByQuickLook() throws {
        let expected = try Behaviour.rule("notice.attachment_copied")
        let files = try FileManager.default.contentsOfDirectory(at: appSources(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("Attachment") || $0.lastPathComponent.contains("QuickLook") }
        #expect(!files.isEmpty)
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(source.contains(".quickLookPreview($preview)"))
        #expect(source.contains("NoticeCenter") == expected.offered)
        #expect(source.contains("postCopied") == expected.offered)
    }

    @Test func rowAccessibilityCopyIsConditional() throws {
        let source = try String(contentsOf: appSources().appending(path: "ItemRow.swift"), encoding: .utf8)
        #expect(source.contains(".accessibilityActions {\n            if copyable {"))
        #expect(!source.contains("if copyable { onCopy() } }"))
    }

    private func appSources() -> URL {
        var url = URL(filePath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appending(path: "NoteBank")
    }
}
