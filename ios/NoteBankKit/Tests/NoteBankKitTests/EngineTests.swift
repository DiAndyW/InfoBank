import Foundation
import GRDB
import Synchronization
import Testing
@testable import NoteBankKit

private let t0: Int64 = 1_760_000_000_000_000

private func eventually(timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return try condition()
}

private final class Statuses: Sendable {
    private let seen = Mutex<[SyncStatus]>([])

    init(_ stream: AsyncStream<SyncStatus>) {
        Task { for await status in stream { seen.withLock { $0.append(status) } } }
    }

    var all: [SyncStatus] { seen.withLock { $0 } }
    var last: SyncStatus? { all.last }
}

private struct Device {
    let store: Store
    let secrets = SecretStore.memory()

    init(url: String, secret: String) throws {
        store = try tempStore().store
        try store.saveSettings(url: url, newSecret: secret, secrets: secrets)
    }

    func engine(poll: Duration = .seconds(60)) -> SyncEngine {
        SyncEngine(store: store, secrets: secrets, pollInterval: poll)
    }

    func feed() throws -> [FeedItem] { try store.items(in: .all, before: nil, limit: 1000) }
}

struct EngineTests {
    private static let emptyPage = #"{"items":[],"topics":[],"tombstones":[],"cursor":0,"has_more":false}"#

    @Test func outcomeTable() {
        #expect(outcome(.success(true), failures: 0) == (.synced, .after(.seconds(10))))
        #expect(outcome(.success(false), failures: 3) == (.synced, .after(.seconds(10))))
        for (failures, seconds) in [(1, 2), (2, 4), (9, 300), (100, 300)] {
            #expect(outcome(.failure(.failed("x")), failures: failures) == (.offline, .after(.seconds(seconds))))
        }
        #expect(outcome(.failure(.unauthorized), failures: 0) == (.unauthorized, .untilSettingsSaved))
        #expect(outcome(.failure(.notConfigured), failures: 0) == (.notConfigured, .untilSettingsSaved))
        #expect(outcome(.failure(.keychain("denied")), failures: 0) == (.keychain, .untilWoken))
    }

    @Test func statusLabels() {
        #expect([SyncStatus.synced, .syncing, .offline, .unauthorized, .keychain, .notConfigured].map(\.label) == [
            "Synced", "Syncing…", "Offline, retrying", "Secret rejected", "Keychain access needed", "",
        ])
    }

    @Test func aWakeSyncsAtOnce() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(url: server.url, secret: server.secret)
        let b = try Device(url: server.url, secret: server.secret)
        let engine = a.engine()
        let statuses = Statuses(engine.status)

        await engine.start()
        #expect(try await eventually { statuses.last == .synced })
        _ = try a.store.capture(text: "from a", topicID: nil, nowUs: t0)
        await engine.wake()

        var queued: [SyncNotice] = []
        let deadline = ContinuousClock.now + .seconds(5)
        var texts: [String] = []
        while texts.isEmpty && ContinuousClock.now < deadline {
            _ = try await cycle(store: b.store, secrets: b.secrets, http: .live, queued: &queued)
            texts = try b.feed().compactMap(\.text)
            if texts.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(texts == ["from a"])
    }

    @Test func aRejectedSecretIsTriedOncePerSave() async throws {
        let fake = try await FakeServer { _ in .json("{}", status: 401) }
        let a = try Device(url: fake.url, secret: "secret")
        let engine = a.engine()
        let statuses = Statuses(engine.status)

        await engine.start()
        #expect(try await eventually { statuses.last == .unauthorized })
        #expect(fake.requests(to: "/sync/pull") == 1)

        await engine.wake()
        await engine.wake()
        await engine.wake()
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.requests(to: "/sync/pull") == 1)

        await engine.settingsSaved()
        #expect(try await eventually { fake.requests(to: "/sync/pull") == 2 })
    }

    @Test func enteringTheBackgroundPushesPendingCaptures() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(url: server.url, secret: server.secret)
        let b = try Device(url: server.url, secret: server.secret)
        let engine = a.engine()
        let statuses = Statuses(engine.status)

        await engine.start()
        #expect(try await eventually { statuses.last == .synced })
        _ = try a.store.capture(text: "typed just before leaving", topicID: nil, nowUs: t0)
        await engine.enterBackground()

        var queued: [SyncNotice] = []
        _ = try await cycle(store: b.store, secrets: b.secrets, http: .live, queued: &queued)
        #expect(try b.feed().map(\.text) == ["typed just before leaving"])
    }

    @Test func theBackgroundDoesNotRetryARejectedSecret() async throws {
        let fake = try await FakeServer { _ in .json("{}", status: 401) }
        let a = try Device(url: fake.url, secret: "secret")
        _ = try a.store.capture(text: "stuck behind the 401", topicID: nil, nowUs: t0)
        let engine = a.engine()
        let statuses = Statuses(engine.status)
        func requests() -> Int { fake.requests(to: "/sync/push") + fake.requests(to: "/sync/pull") }

        await engine.start()
        #expect(try await eventually { statuses.last == .unauthorized })
        #expect(requests() == 1)

        await engine.enterBackground()
        await engine.enterBackground()
        #expect(requests() == 1)

        await engine.enterForeground()
        #expect(requests() == 1)
        await engine.settingsSaved()
        #expect(try await eventually { requests() == 2 })
    }

    @Test func theBackgroundDoesNotRetryAnUnreadableKeychain() async throws {
        let server = try await FakeServer { _ in .json(Self.emptyPage) }
        let a = try Device(url: server.url, secret: "secret")
        _ = try a.store.capture(text: "waiting for the keychain", topicID: nil, nowUs: t0)
        let reads = Mutex(0)
        let locked = SecretStore(
            read: {
                reads.withLock { $0 += 1 }
                throw KeychainError(status: errSecInteractionNotAllowed)
            },
            write: { _ in })
        let engine = SyncEngine(store: a.store, secrets: locked, pollInterval: .seconds(60))
        let statuses = Statuses(engine.status)

        await engine.start()
        #expect(try await eventually { statuses.last == .keychain })
        await engine.enterBackground()

        #expect(reads.withLock { $0 } == 1)
    }

    @Test func theLoopStillPollsAfterABackgroundTripFollowingASettingsSave() async throws {
        let accepting = Mutex(false)
        let fake = try await FakeServer { request in
            guard accepting.withLock({ $0 }) else { return .json("{}", status: 401) }
            guard request.path == "/sync/push" else { return .json(Self.emptyPage) }
            let ops = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["ops"] as? [[String: Any]] ?? []
            let results = ops.map { #"{"op_id":"\#($0["id"] as! String)","status":"accepted","reason":null,"text":null}"# }
            return .json(#"{"results":[\#(results.joined(separator: ","))]}"#)
        }
        let a = try Device(url: fake.url, secret: "secret")
        _ = try a.store.capture(text: "first", topicID: nil, nowUs: t0)
        let engine = a.engine(poll: .milliseconds(200))
        let statuses = Statuses(engine.status)

        await engine.start()
        #expect(try await eventually { statuses.last == .unauthorized })
        accepting.withLock { $0 = true }
        let leaving = Task { await engine.enterBackground() }
        await engine.settingsSaved()
        await leaving.value
        await engine.enterForeground()
        #expect(try await eventually { statuses.last == .synced })
        await engine.enterBackground()
        await engine.enterForeground()

        let pushes = fake.requests(to: "/sync/push")
        _ = try a.store.capture(text: "second", topicID: nil, nowUs: t0 + 1)
        await engine.wake()
        #expect(try await eventually { fake.requests(to: "/sync/push") > pushes })
    }

    @Test func statusShowsSyncingOnlyWithPendingOps() async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/push" ? .json(#"{"results":[]}"#) : .json(Self.emptyPage)
        }
        let a = try Device(url: fake.url, secret: "secret")
        let engine = a.engine()
        let statuses = Statuses(engine.status)

        await engine.start()
        #expect(try await eventually { statuses.last == .synced })
        await engine.wake()
        #expect(try await eventually { fake.requests(to: "/sync/pull") == 2 })
        #expect(statuses.all == [.synced])
    }

    @Test func statusShowsSyncingWhileOpsArePending() async throws {
        let fake = try await FakeServer { request in
            guard request.path == "/sync/push" else { return .json(Self.emptyPage) }
            let ops = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["ops"] as? [[String: Any]] ?? []
            let results = ops.map { #"{"op_id":"\#($0["id"] as! String)","status":"accepted","reason":null,"text":null}"# }
            return .json(#"{"results":[\#(results.joined(separator: ","))]}"#)
        }
        let a = try Device(url: fake.url, secret: "secret")
        let engine = a.engine()
        let statuses = Statuses(engine.status)

        await engine.start()
        #expect(try await eventually { statuses.last == .synced })
        _ = try a.store.capture(text: "pending", topicID: nil, nowUs: t0)
        await engine.wake()

        #expect(try await eventually { statuses.all == [.synced, .syncing, .synced] })
    }
}
