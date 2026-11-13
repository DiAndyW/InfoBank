import Foundation
import Testing
@testable import NoteBankKit

@MainActor struct TopicDeletionModelTests {
    @Test func pagesSearchesAndKeepsTicksAcrossQueries() async throws {
        let store = try tempStore().store
        let topic = try store.createTopic(name: "Library", nowUs: 1)
        var ids: [String] = []
        for n in 0..<60 {
            ids.append(try store.capture(text: "Library note \(n)", to: .topic(topic), nowUs: Int64(n + 2)))
        }
        _ = try store.capture(text: "Library outsider", to: .inbox, nowUs: 90)
        let model = TopicDeletionModel(store: store, topicID: topic, debounce: .zero)
        #expect(model.total == 60)
        #expect(model.items.count == 50)
        #expect(model.hasMore)
        model.loadMore()
        #expect(model.items.map(\.id) == ids.reversed())
        #expect(!model.hasMore)
        model.kept = [ids[0], ids[59]]
        model.text = "note 59"
        #expect(await waitUntil { model.items.map(\.id) == [ids[59]] })
        #expect(model.total == 60)
        #expect(model.kept == [ids[0], ids[59]])
        model.text = "no matches"
        #expect(await waitUntil { model.items.isEmpty })
        model.text = ""
        #expect(model.items.count == 50)
        #expect(model.kept == [ids[0], ids[59]])
        model.loadMore()
        #expect(model.items.count == 60)
    }

    @Test func confirmationCountsCurrentMembershipAndDeletesWithSamePolicy() throws {
        let store = try tempStore().store
        let topic = try store.createTopic(name: "Library", nowUs: 1)
        let kept = try store.capture(text: "Keep", to: .topic(topic), nowUs: 2)
        let moved = try store.capture(text: "Moved away", to: .topic(topic), nowUs: 3)
        let trashed = try store.capture(text: "Already trashed", to: .topic(topic), nowUs: 4)
        let model = TopicDeletionModel(store: store, topicID: topic)
        model.kept = [kept, moved, trashed]
        try store.move(itemID: moved, to: .inbox, nowUs: 5)
        try store.trash(itemID: trashed, nowUs: 6)
        let arrived = try store.capture(text: "Arrived during selection", to: .topic(topic), nowUs: 7)
        #expect(try model.confirmationMessage() == "1 Item moves to the Inbox. 1 goes to Trash.")
        #expect(model.total == 2)
        #expect(model.kept == [kept])
        try store.deleteTopic(topic, keeping: .only(model.kept), nowUs: 8)
        #expect(try store.items(in: .inbox, before: nil, limit: 10).map(\.id).sorted() == [kept, moved].sorted())
        #expect(Set(try store.items(in: .trash, before: nil, limit: 10).map(\.id)) == [trashed, arrived])
    }

    @Test func confirmationWithoutTicksAndWithAllTicks() throws {
        let store = try tempStore().store
        let topic = try store.createTopic(name: "Library", nowUs: 1)
        let id = try store.capture(text: "Only", to: .topic(topic), nowUs: 2)
        let model = TopicDeletionModel(store: store, topicID: topic)
        #expect(try model.confirmationMessage() == "All 1 Item goes to Trash.")
        model.kept = [id]
        #expect(try model.confirmationMessage() == "1 Item moves to the Inbox. 0 go to Trash.")
        _ = try store.capture(text: "Another", to: .topic(topic), nowUs: 3)
        model.kept = []
        #expect(try model.confirmationMessage() == "All 2 Items go to Trash.")
    }
}
