import GRDB
import Observation
import Synchronization
import Testing
@testable import NoteBankKit

extension QuickCaptureSuspensionTests {
    @Test @MainActor func draftSaveDoesNotRepeatThroughViewInvalidation() async throws {
        let store = try Store(at: tempStore().file)
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .home, onCaptured: {})
        model.text = "Keep this text"
        model.flushDraft()
        store.suspendFileDatabaseAccess()
        defer { store.resumeFileDatabaseAccess() }
        let view = DraftViewUpdates(model: model)
        view.update()
        defer { view.stopped = true }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(view.invalidations == 0)
        #expect(model.error == nil)
        #expect(model.text == "Keep this text")
        store.resumeFileDatabaseAccess()
        model.text = "Keep this text after resume"
        model.flushDraft()
        #expect(try store.drafts()[.home]?.text == "Keep this text after resume")
    }

    @Test @MainActor func realDraftWriteFailureStillWarnsAndRecovers() throws {
        let store = try tempStore().store
        let model = ComposerModel(store: store, destination: .inbox, placeholder: "", draft: .inbox, onCaptured: {})
        try store.pool.write { try $0.execute(sql: """
            CREATE TRIGGER fail_draft BEFORE INSERT ON drafts BEGIN
                SELECT RAISE(ABORT, 'draft write failed');
            END;
            """) }
        model.text = "Unsaved text"
        for _ in 0..<3 { model.flushDraft() }
        #expect(model.error == "Couldn't save your draft. Your text is still here.")
        #expect(model.text == "Unsaved text")
        #expect(try store.drafts()[.inbox] == nil)
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER fail_draft") }
        model.flushDraft()
        #expect(model.error == nil)
        #expect(try store.drafts()[.inbox]?.text == "Unsaved text")
    }

    @Test @MainActor func observationsStayQuietWhileSuspended() async throws {
        let store = try Store(at: tempStore().file)
        try await store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name) VALUES ('t', 'Topic')") }
        let changes = Mutex(0)
        let failures = Mutex(0)
        let observation = store.observeChanges(onChange: { changes.withLock { $0 += 1 } }, onError: { _ in failures.withLock { $0 += 1 } })
        defer { observation.cancel(); store.resumeFileDatabaseAccess() }
        let feed = FeedModel(store: store, place: .all)
        let places = PlacesModel(store: store)
        let search = SearchModel(store: store, debounce: .zero)
        let deletion = TopicDeletionModel(store: store, topicID: "t")
        search.text = "Fresh"
        store.suspendFileDatabaseAccess()
        try await Task.sleep(for: .milliseconds(500))
        #expect(changes.withLock { $0 } == 0)
        #expect(failures.withLock { $0 } == 0)
        #expect(feed.loadError == nil)
        #expect(search.error == nil)
        #expect(deletion.error == nil)
        #expect(places.places.allCount == 0)
        store.resumeFileDatabaseAccess()
        let id = try store.capture(text: "Fresh value", to: .topic("t"), nowUs: 1)
        #expect(await waitUntil {
            feed.items.contains { $0.id == id } && places.places.allCount == 1
                && search.results.contains { $0.item.id == id } && deletion.total == 1
        })
    }

    @Test @MainActor func constructingFeedWhileSuspendedDoesNotInvalidateItsParent() async throws {
        let store = try Store(at: tempStore().file)
        store.suspendFileDatabaseAccess()
        defer { store.resumeFileDatabaseAccess() }
        let changes = Mutex(0)
        var feed: FeedModel?
        withObservationTracking {
            feed = FeedModel(store: store, place: .inbox)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(changes.withLock { $0 } == 0)
        #expect(feed?.loadError == nil)
    }
}

@MainActor private final class DraftViewUpdates {
    let model: ComposerModel
    var invalidations = 0
    var stopped = false

    init(model: ComposerModel) { self.model = model }

    func update() {
        guard !stopped else { return }
        withObservationTracking {
            model.homeTopicID = nil
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.invalidations += 1
                self.update()
            }
        }
    }
}
