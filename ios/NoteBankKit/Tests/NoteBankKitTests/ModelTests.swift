import Foundation
import GRDB
import Synchronization
import Testing
@testable import NoteBankKit

@MainActor
struct ModelTests {
    private func seed(_ store: Store, count: Int, topic: String? = nil) throws {
        try store.pool.write { db in
            for n in 1...count {
                try db.execute(
                    sql: "INSERT INTO items (id, topic_id, text, capture_time) VALUES (?, ?, ?, ?)",
                    arguments: ["i\(n)", topic, "text \(n)", Int64(n) * 10])
            }
        }
    }

    @Test func feedLoadsTheNewestPageOldestFirstAndOlderPagesPrepend() throws {
        let (store, _) = try tempStore()
        try seed(store, count: 150)
        let feed = FeedModel(store: store, place: .all)
        #expect(feed.items.map(\.id) == (51...150).map { "i\($0)" })
        #expect(feed.hasOlder)
        feed.loadOlder()
        #expect(feed.items.map(\.id) == (1...150).map { "i\($0)" })
        #expect(!feed.hasOlder)
        #expect(feed.loadError == nil)
    }

    @Test func aFullLastPageLeavesHasOlderUntilAnEmptyOneClearsIt() throws {
        let (store, _) = try tempStore()
        try seed(store, count: 100)
        let feed = FeedModel(store: store, place: .all)
        #expect(feed.hasOlder)
        feed.loadOlder()
        #expect(!feed.hasOlder)
        #expect(feed.items.count == 100)
    }

    @Test func aPullOrCaptureRefreshesTheLoadedRange() async throws {
        let (store, _) = try tempStore()
        try seed(store, count: 150)
        let feed = FeedModel(store: store, place: .all)

        let captured = try store.capture(text: "fresh", to: .inbox, nowUs: 5_000)
        #expect(await waitUntil { feed.items.last?.id == captured })
        #expect(feed.items.count == 101)
        #expect(feed.items.last?.pending == true)

        try await store.pool.write { try $0.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('mid', 'pulled', 755)") }
        #expect(await waitUntil { feed.items.contains { $0.id == "mid" } })
        #expect(feed.items.map(\.id).firstIndex(of: "mid")! == feed.items.map(\.id).firstIndex(of: "i75")! + 1)

        try await store.pool.write { try $0.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('old', 'pulled', 5)") }
        try await store.pool.write { try $0.execute(sql: "UPDATE items SET text = 'edited' WHERE id = 'i150'") }
        #expect(await waitUntil { feed.items.first { $0.id == "i150" }?.text == "edited" })
        #expect(!feed.items.contains { $0.id == "old" })
    }

    @Test func revealLoadsAnOlderItemWithAPageAboveIt() throws {
        let (store, _) = try tempStore()
        try seed(store, count: 300)
        let feed = FeedModel(store: store, place: .inbox)
        #expect(!feed.items.contains { $0.id == "i150" })
        #expect(feed.reveal("i150"))
        #expect(feed.items.map(\.id) == (50...300).map { "i\($0)" })
        #expect(feed.hasOlder)
        #expect(feed.reveal("i10"))
        #expect(feed.items.map(\.id) == (1...300).map { "i\($0)" })
        #expect(!feed.hasOlder)
        #expect(feed.reveal("i300"))
        #expect(feed.items.count == 300)
    }

    @Test func revealFalseForTrashedOrUnknown() throws {
        let (store, _) = try tempStore()
        try seed(store, count: 150)
        let feed = FeedModel(store: store, place: .all)
        try store.trash(itemID: "i1", nowUs: 5_000)
        let before = feed.items.map(\.id)
        #expect(!feed.reveal("i1"))
        #expect(!feed.reveal("nope"))
        #expect(feed.items.map(\.id) == before)
        #expect(feed.hasOlder)
    }

    @Test func revealDoesNothingInTrash() throws {
        let (store, _) = try tempStore()
        try seed(store, count: 150)
        try store.pool.write { try $0.execute(sql: "UPDATE items SET deleted_at = 1, purge_at = ?", arguments: [Time.nowUs() + 1_000_000_000_000]) }
        let feed = FeedModel(store: store, place: .trash)
        let before = feed.items.map(\.id)
        #expect(before.count == 100)
        #expect(!feed.reveal("i1"))
        #expect(feed.items.map(\.id) == before)
    }

    @Test func anItemOlderThanEverythingLoadedMakesOlderAvailable() async throws {
        let (store, _) = try tempStore()
        try seed(store, count: 3)
        let feed = FeedModel(store: store, place: .all)
        #expect(!feed.hasOlder)

        try await store.pool.write { try $0.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('old', 'skewed clock', 5)") }
        #expect(await waitUntil { feed.hasOlder })
        #expect(feed.items.map(\.id) == ["i1", "i2", "i3"])
        feed.loadOlder()
        #expect(feed.items.map(\.id) == ["old", "i1", "i2", "i3"])
        #expect(!feed.hasOlder)
    }

    @Test func anEmptyFeedLoadsItsFirstPageWhenItemsArrive() async throws {
        let (store, _) = try tempStore()
        let feed = FeedModel(store: store, place: .inbox)
        #expect(feed.items.isEmpty && !feed.hasOlder)
        try seed(store, count: 3)
        #expect(await waitUntil { feed.items.count == 3 })
    }

    @Test func discardingARefusedItemRemovesItAndAnythingElseSetsTheError() async throws {
        let (store, _) = try tempStore()
        let id = try store.capture(text: "refused", to: .inbox, nowUs: 1)
        let feed = FeedModel(store: store, place: .all)
        feed.discard(id)
        #expect(feed.loadError == "Only an Item the Server refused can be discarded")
        #expect(feed.items.count == 1)
        try await store.pool.write { try $0.execute(sql: "UPDATE items SET sync_error = 'invalid' WHERE id = ?", arguments: [id]) }
        feed.discard(id)
        #expect(feed.items.isEmpty)
    }

    @Test func placesFollowTheStore() async throws {
        let (store, _) = try tempStore()
        let places = PlacesModel(store: store)
        #expect(places.places.allCount == 0)
        _ = try store.capture(text: "one", to: .inbox, nowUs: 1)
        #expect(await waitUntil { places.places.inboxCount == 1 })
    }

    @Test func refreshReadsTheStoreAtOnce() throws {
        let (store, _) = try tempStore()
        let places = PlacesModel(store: store)
        _ = try store.capture(text: "one", to: .inbox, nowUs: 1)
        places.refresh()
        #expect(places.places.inboxCount == 1)
    }

    @Test func composerSendDisabledWhenBlankAndTextKeptOnError() throws {
        let (store, _) = try tempStore()
        let captured = Mutex(0)
        let composer = ComposerModel(store: store, destination: .inbox, placeholder: "Capture to the Inbox", onCaptured: { captured.withLock { $0 += 1 } })
        #expect(!composer.canSend)
        composer.text = "  \n "
        #expect(!composer.canSend)

        composer.text = String(repeating: "a", count: (1 << 20) + 1)
        #expect(composer.canSend)
        #expect(!composer.send())
        #expect(composer.error == "That's too long to save (1 MB max)")
        #expect(composer.text.utf8.count == (1 << 20) + 1)
        #expect(captured.withLock { $0 } == 0)

        composer.text = "ok"
        #expect(composer.send())
        #expect(composer.text.isEmpty)
        #expect(composer.error == nil)
        #expect(captured.withLock { $0 } == 1)
    }

    @Test func composerPlaceholderNamesThePlace() throws {
        let (store, _) = try tempStore()
        #expect(ComposerModel(store: store, destination: .tunnel, placeholder: "Send to your other devices…", onCaptured: {}).placeholder == "Send to your other devices…")
    }

    @Test func aClosedTopicFallsBackToTheInbox() throws {
        let (store, _) = try tempStore()
        let composer = ComposerModel(store: store, destination: .topic("t1"), placeholder: "", onCaptured: {})
        composer.dropMissingTopic(open: [TopicPlace(id: "t1", name: "Mosaic", count: 0)])
        #expect(composer.destination == .topic("t1"))
        composer.dropMissingTopic(open: [TopicPlace(id: "t2", name: "Other", count: 0)])
        #expect(composer.destination == .inbox)
        composer.destination = .tunnel
        composer.dropMissingTopic(open: [])
        #expect(composer.destination == .tunnel)
    }

    @Test func aTopicComposerCapturesIntoThatTopic() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name) VALUES ('t1', 'Mosaic')") }
        let topic = ComposerModel(store: store, destination: .topic("t1"), placeholder: "", onCaptured: {})
        topic.text = "into the topic"
        #expect(topic.send())
        let inbox = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {})
        inbox.text = "into the inbox"
        #expect(inbox.send())
        let tunnel = ComposerModel(store: store, destination: .tunnel, placeholder: "", onCaptured: {})
        tunnel.text = "into the tunnel"
        #expect(tunnel.send())
        tunnel.destination = .topic("t1")
        tunnel.text = "retargeted"
        #expect(tunnel.send())
        #expect(try store.items(in: .topic("t1"), before: nil, limit: 10).map(\.text) == ["retargeted", "into the topic"])
        #expect(try store.items(in: .tunnel, before: nil, limit: 10).map(\.text) == ["into the tunnel"])
        #expect(try store.items(in: .inbox, before: nil, limit: 10).map(\.text) == ["into the inbox"])
    }

    @Test func firstLaunchNeedsBothFieldsToSave() async throws {
        let (store, _) = try tempStore()
        let saved = Mutex(0)
        let settings = SettingsModel(store: store, secrets: .memory(), check: .accepting, onSaved: { saved.withLock { $0 += 1 } })
        #expect(settings.needsSetup && !settings.hasSecret && !settings.canSave)
        settings.url = "https://notes.example.com"
        #expect(!settings.canSave)
        settings.url = ""
        settings.secret = "s3cret-s3cret"
        #expect(!settings.canSave)
        settings.url = "https://notes.example.com"
        #expect(settings.canSave)

        #expect(await settings.save())
        #expect(!settings.needsSetup && settings.hasSecret)
        #expect(settings.secret.isEmpty && settings.error == nil && !settings.saving)
        #expect(saved.withLock { $0 } == 1)

        #expect(settings.canSave)
        settings.url = "https://other.example.com"
        #expect(!(await settings.save()))
        #expect(settings.error == "Enter the secret again for a new Server")
        #expect(saved.withLock { $0 } == 1)
    }

    @Test func settingsLoadWhatIsSaved() async throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://notes.example.com/", newSecret: "s3cret-s3cret", secrets: secrets)
        let settings = SettingsModel(store: store, secrets: secrets, check: .accepting, onSaved: {})
        #expect(settings.url == "https://notes.example.com")
        #expect(settings.hasSecret && !settings.needsSetup)
    }

    @Test func aSavedURLWithoutASecretNeedsSetupWithTheURLFilledIn() async throws {
        let (store, _) = try tempStore()
        try store.saveSettings(url: "https://notes.example.com", newSecret: "s3cret-s3cret", secrets: .memory())
        let settings = SettingsModel(store: store, secrets: .memory(), check: .accepting, onSaved: {})
        #expect(settings.needsSetup && !settings.hasSecret)
        #expect(settings.url == "https://notes.example.com")
        #expect(!settings.canSave)
        settings.secret = "another-s3cret"
        #expect(settings.canSave)
        #expect(await settings.save())
        #expect(!settings.needsSetup && settings.hasSecret)
    }

    @Test func aKeychainReadErrorDoesNotShowSetup() throws {
        let (store, _) = try tempStore()
        try store.saveSettings(url: "https://notes.example.com", newSecret: "s3cret-s3cret", secrets: .memory())
        let locked = SecretStore(read: { throw KeychainError(status: errSecInteractionNotAllowed) }, write: { _ in })
        let settings = SettingsModel(store: store, secrets: locked, check: .accepting, onSaved: {})
        #expect(!settings.needsSetup)
        #expect(settings.error?.hasPrefix("Couldn't read the keychain") == true)
    }

    @Test func aSecondSaveWhileSavingIsIgnored() async throws {
        let (store, _) = try tempStore()
        let writes = Mutex(0)
        let gate = DispatchSemaphore(value: 0)
        let secrets = SecretStore(read: { nil }, write: { _ in
            writes.withLock { $0 += 1 }
            _ = gate.wait(timeout: .now() + 3)
        })
        let settings = SettingsModel(store: store, secrets: secrets, check: .accepting, onSaved: {})
        settings.url = "https://notes.example.com"
        settings.secret = "s3cret-s3cret"

        let first = Task { await settings.save() }
        #expect(await waitUntil { settings.saving })
        #expect(!settings.canSave)
        #expect(!(await settings.save()))
        gate.signal()
        #expect(await first.value)
        #expect(writes.withLock { $0 } == 1)
        #expect(!settings.saving)
    }

    @Test func aFailedSaveKeepsTheSecretAndShowsTheError() async throws {
        let (store, _) = try tempStore()
        let settings = SettingsModel(store: store, secrets: .memory(), check: .accepting, onSaved: {})
        settings.url = "http://notes.example.com"
        settings.secret = "s3cret-s3cret"
        #expect(!(await settings.save()))
        #expect(settings.error == "The Server URL must start with https://")
        #expect(settings.secret == "s3cret-s3cret")
        #expect(settings.needsSetup)
    }

    @Test func noticeCenterShowsTheLastAndTheCount() {
        let center = NoticeCenter()
        #expect(center.current == nil)
        center.post([])
        #expect(center.current == nil)

        let one = SyncNotice(itemID: "a", label: "first", topicName: nil, topicID: nil, topicState: nil)
        let two = SyncNotice(itemID: "b", label: "second", topicName: "Mosaic", topicID: "t1", topicState: .archived)
        let three = SyncNotice(itemID: "c", label: "third", topicName: "Mosaic", topicID: "t1", topicState: .deleted)
        center.post([one])
        #expect(center.current?.message == one.message)
        #expect(center.current?.itemID == "a")
        center.post([one, two, three])
        #expect(center.current?.message == three.message + " And 2 more.")
        #expect(center.current?.itemID == "c")
        center.dismiss()
        #expect(center.current == nil)
    }
}

extension ModelTests {
    @Test func settingsRefreshesTheSyncedCopySwitchWithoutClobberingServerDrafts() async throws {
        let store = try tempStore().store
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://notes.example.com", newSecret: "secret", secrets: secrets)
        let settings = SettingsModel(store: store, secrets: secrets, check: .accepting, onSaved: {})
        settings.url = "https://draft.example.com"
        settings.secret = "unsaved"
        let json = #"{"items":[],"topics":[],"tombstones":[],"cursor":0,"has_more":false,"settings":{"trash_after_copy":true}}"#
        _ = try store.applyPull(try JSONDecoder().decode(PullPage.self, from: Data(json.utf8)), serverURL: "https://notes.example.com")
        #expect(await waitUntil { settings.trashAfterCopy })
        #expect(settings.url == "https://draft.example.com")
        #expect(settings.secret == "unsaved")
        #expect(settings.setTrashAfterCopy(false))
        _ = try store.applyPull(try JSONDecoder().decode(PullPage.self, from: Data(json.utf8)), serverURL: "https://notes.example.com")
        #expect(try store.trashAfterCopy() == false)
        #expect(!settings.trashAfterCopy)
    }
}

@MainActor final class Saves { var count = 0 }

extension ModelTests {
    private func connectedToA() throws -> (settings: SettingsModel, store: Store, secrets: SecretStore, saved: Saves) {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1)")
            try db.execute(sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES ('f1', 'pulled', 'f.png', 'image/png', 1, 0, 0)")
        }
        let saved = Saves()
        let settings = SettingsModel(store: store, secrets: secrets, check: .accepting, onSaved: { saved.count += 1 })
        settings.url = "https://b.example.com"
        settings.secret = "other-s3cret"
        return (settings, store, secrets, saved)
    }

    @Test func aStrandedRefusalAsksInsteadOfShowingAnError() async throws {
        let (settings, _, _, saved) = try connectedToA()
        #expect(!(await settings.save()))
        #expect(settings.stranded?.stranded == Stranded(changes: 0, files: 1))
        #expect(settings.error == nil)
        #expect(settings.url == "https://b.example.com" && settings.secret == "other-s3cret")
        #expect(saved.count == 0)
        settings.cancelDiscard()
        #expect(settings.stranded == nil)
    }

    @Test func anErrorFromAnEarlierAttemptIsGoneWhenTheDiscardAlertAppears() async throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1)")
            try db.execute(sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES ('f1', 'pulled', 'f.png', 'image/png', 1, 0, 0)")
        }
        let calls = Mutex(0)
        let flaky = ServerCheck(run: { _, _ throws(SettingsError) in
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw SettingsError(message: "Couldn't reach the Server.") }
        })
        let settings = SettingsModel(store: store, secrets: secrets, check: flaky, onSaved: {})
        settings.url = "https://b.example.com"
        settings.secret = "other-s3cret"
        #expect(!(await settings.save()))
        #expect(settings.error == "Couldn't reach the Server.")
        #expect(!(await settings.save()))
        #expect(settings.stranded != nil)
        #expect(settings.error == nil)
    }

    @Test func switchAnywaySavesWithTheConfirmedCounts() async throws {
        let (settings, store, _, saved) = try connectedToA()
        _ = await settings.save()
        #expect(await settings.save(confirmed: settings.stranded!.stranded!))
        #expect(settings.stranded == nil)
        #expect(saved.count == 1)
        #expect(try store.serverURL() == "https://b.example.com")
    }

    @Test func aRejectedSecretShowsTheMessageAndChangesNothing() async throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        let rejecting = ServerCheck(run: { _, _ throws(SettingsError) in throw SettingsError(message: "The Server rejected this secret.") })
        let settings = SettingsModel(store: store, secrets: secrets, check: rejecting, onSaved: {})
        settings.url = "https://notes.example.com"
        settings.secret = "wrong-s3cret"
        #expect(!(await settings.save()))
        #expect(settings.error == "The Server rejected this secret.")
        #expect(try secrets.read() == nil)
        #expect(try store.serverURL() == nil)
    }

    @Test func noCheckWhenNoSecretIsTyped() async throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://notes.example.com", newSecret: "s3cret-s3cret", secrets: secrets)
        let calls = Mutex(0)
        let counting = ServerCheck(run: { _, _ in calls.withLock { $0 += 1 } })
        let settings = SettingsModel(store: store, secrets: secrets, check: counting, onSaved: {})
        #expect(await settings.save())
        #expect(calls.withLock { $0 } == 0)
        settings.secret = "new-s3cret"
        #expect(await settings.save())
        #expect(calls.withLock { $0 } == 1)
    }
}
