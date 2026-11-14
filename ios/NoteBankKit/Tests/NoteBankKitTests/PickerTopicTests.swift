import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct PickerTopicTests {
    private func outboxTypes(_ store: Store) throws -> [String] {
        try store.pool.read { try String.fetchAll($0, sql: "SELECT json_extract(op, '$.type') FROM outbox ORDER BY seq") }
    }

    @Test func createsATopicWhenNothingMatches() throws {
        let store = try tempStore().store
        let id = try store.pickerTopic(named: "  Mosaic ", nowUs: 1)
        #expect(try store.places().topics.map(\.name) == ["Mosaic"])
        #expect(try store.places().topics.map(\.id) == [id])
        #expect(try outboxTypes(store) == ["CreateTopic"])
    }

    @Test func reusesAnOpenTopicWithoutQueueingAnything() throws {
        let store = try tempStore().store
        let existing = try store.createTopic(name: "Mosaic", nowUs: 1)
        #expect(try store.pickerTopic(named: " mOSAIC ", nowUs: 2) == existing)
        #expect(try store.places().topics.count == 1)
        #expect(try outboxTypes(store) == ["CreateTopic"])
    }

    @Test func refusesBuiltInBlankAndControlNamesEverywhereAndQueuesNothing() throws {
        let store = try tempStore().store
        let gym = try store.createTopic(name: "Gym", nowUs: 1)
        for name in ["inbox", " TUNNEL ", "Trash", "all items", "Anywhere", "New Topic", "new topic…", "New Topic...", "\u{200b}", " \u{2060}\u{feff} ", "a\nb", "tab\there"] {
            #expect(throws: (any Error).self, "create \(name.debugDescription)") { try store.createTopic(name: name, nowUs: 2) }
            #expect(throws: (any Error).self, "rename \(name.debugDescription)") { try store.renameTopic(gym, name: name, nowUs: 2) }
            #expect(throws: (any Error).self, "picker \(name.debugDescription)") { try store.pickerTopic(named: name, nowUs: 2) }
            #expect(try store.pickerTopicProblem(named: name) != nil, "no reason for \(name.debugDescription)")
        }
        #expect(try store.pickerTopicProblem(named: "Inbox") == "“Inbox” is a built-in name. Pick another.")
        #expect(try outboxTypes(store) == ["CreateTopic"])
        for name in ["Inbox ideas", "New Topics", "Mom's recipes; DROP TABLE topics"] {
            _ = try store.createTopic(name: name, nowUs: 3)
        }
    }

    @Test func problemMatchesWhatPickerTopicWouldDoAndWritesNothing() throws {
        let store = try tempStore().store
        let deleted = try store.createTopic(name: "Old", nowUs: 1)
        try store.deleteTopic(deleted, keeping: .all, nowUs: 2)
        _ = try store.createTopic(name: "Mosaic", nowUs: 3)
        #expect(try store.pickerTopicProblem(named: " oLD ") == nil)
        #expect(try store.pickerTopicProblem(named: "mosaic") == nil)
        #expect(try store.pickerTopicProblem(named: "Fresh") == nil)
        #expect(try store.pickerTopicProblem(named: "   ") != nil)
        #expect(try store.pickerTopicProblem(named: String(repeating: "x", count: 201)) != nil)
        #expect(try outboxTypes(store) == ["CreateTopic", "DeleteTopic", "CreateTopic"])
    }

    @Test func invalidNamesAreRefused() throws {
        let store = try tempStore().store
        for name in ["", "   ", "a\0b", String(repeating: "x", count: 201)] {
            #expect(throws: AttachmentError.self) { try store.pickerTopic(named: name, nowUs: 1) }
        }
        #expect(try outboxTypes(store).isEmpty)
    }

    @Test func createTopicStillRefusesAnExistingName() throws {
        let store = try tempStore().store
        _ = try store.createTopic(name: "Mosaic", nowUs: 1)
        let error = #expect(throws: AttachmentError.self) { try store.createTopic(name: "mosaic", nowUs: 2) }
        #expect(error?.message == "A Topic with that name already exists")
    }

    @Test func newTopicIsQueuedBeforeTheCaptureOffline() throws {
        let store = try tempStore().store
        let id = try store.pickerTopic(named: "Mosaic", nowUs: 1)
        let item = try store.capture(text: "tile ideas", to: .topic(id), nowUs: 2)
        #expect(try outboxTypes(store) == ["CreateTopic", "CaptureItem"])
        #expect(try store.items(in: .topic(id), before: nil, limit: 10).map(\.id) == [item])
    }

    @Test func newTopicIsQueuedBeforeAMoveOffline() throws {
        let store = try tempStore().store
        let item = try store.capture(text: "tile ideas", to: .inbox, nowUs: 1)
        let id = try store.pickerTopic(named: "Mosaic", nowUs: 2)
        try store.move(itemID: item, to: .topic(id), nowUs: 3)
        #expect(try outboxTypes(store) == ["CaptureItem", "CreateTopic", "MoveItem"])
        #expect(try store.items(in: .topic(id), before: nil, limit: 10).map(\.id) == [item])
    }

    @Test @MainActor func theShareDraftSwitchesToANewTopicAndSavesIntoIt() throws {
        let store = try tempStore().store
        let model = ShareCaptureModel(store: store)
        model.extraText = "tile ideas"
        try model.chooseNewTopic(named: "Mosaic")
        let id = try #require(model.topics.first?.id)
        #expect(model.topics.map(\.name) == ["Mosaic"])
        #expect(model.destination == .topic(id))
        let item = try #require(model.save())
        #expect(try store.items(in: .topic(id), before: nil, limit: 10).map(\.id) == [item])
        #expect(try outboxTypes(store) == ["CreateTopic", "CaptureItem"])
    }

    @Test @MainActor func theShareDraftKeepsItsDestinationWhenTheNameIsRefused() throws {
        let store = try tempStore().store
        let model = ShareCaptureModel(store: store)
        #expect(throws: AttachmentError.self) { try model.chooseNewTopic(named: " ") }
        #expect(model.destination == .inbox)
    }

    @Test func aShareToANewTopicSendsItsCreateTopicWithTheCapture() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let topic = try store.pickerTopic(named: "Mosaic", nowUs: Time.nowUs())
        let shared = try store.capture(text: "https://example.com", to: .topic(topic), nowUs: Time.nowUs())
        let inbox = try await pushSharedCapture(shared, store: store, secrets: secrets)
        #expect(!inbox)
        #expect(try store.items(in: .topic(topic), before: nil, limit: 10).map(\.id) == [shared])
        #expect(try outboxTypes(store).isEmpty)
        let (other, _) = try tempStore()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        var notices: [SyncNotice] = []
        _ = try await cycle(store: other, secrets: secrets, http: .live, queued: &notices)
        #expect(try other.items(in: .topic(topic), before: nil, limit: 10).map(\.id) == [shared])
    }
}
