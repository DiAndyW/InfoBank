import Foundation
import GRDB
import Synchronization
import Testing
@testable import NoteBankKit

// In the past, so the Server's cap on future timestamps never applies.
private let t0: Int64 = 1_760_000_000_000_000
private let second: Int64 = 1_000_000

private final class Device {
    let store: Store
    let secrets = SecretStore.memory()
    var queued: [SyncNotice] = []

    init(url: String, secret: String) throws {
        store = try tempStore().store
        try store.saveSettings(url: url, newSecret: secret, secrets: secrets)
    }

    convenience init(_ server: TestServer, secret: String? = nil) throws {
        try self.init(url: server.url, secret: secret ?? server.secret)
    }

    @discardableResult
    func sync() async throws(SyncFailure) -> Bool {
        try await cycle(store: store, secrets: secrets, http: .live, queued: &queued)
    }

    func syncFailure() async -> SyncFailure? {
        do throws(SyncFailure) {
            _ = try await sync()
            return nil
        } catch { return error }
    }

    func capture(_ text: String, at nowUs: Int64, to destination: Destination = .inbox) throws -> String {
        try store.capture(text: text, to: destination, nowUs: nowUs)
    }

    func feed() throws -> [FeedItem] { try store.items(in: .all, before: nil, limit: 1000) }

    func count(_ table: String) throws -> Int {
        try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)")! }
    }

    func cursor() throws -> Int64 { try store.pool.read { try Int64.fetchOne($0, sql: "SELECT pull_cursor FROM device")! } }
}

private func newID() -> String { UUID().uuidString.lowercased() }

struct ServerCycleTests {
    @Test func anOfflineCaptureReachesAnotherDeviceInCaptureTimeOrder() async throws {
        let server = try TestServer()
        let a = try Device(server)
        let b = try Device(server)

        _ = try a.capture("captured offline", at: t0 + 2 * second)
        let failure = await a.syncFailure()
        guard case .failed(let reason) = failure else {
            Issue.record("expected .failed, got \(String(describing: failure))")
            return
        }
        #expect(!reason.contains("127.0.0.1") && !reason.contains(String(server.port)))
        #expect(try a.count("outbox") == 1)

        try await server.start()
        _ = try b.capture("b first", at: t0 + 1 * second)
        _ = try b.capture("b last", at: t0 + 3 * second)
        _ = try await a.sync()
        _ = try await b.sync()

        #expect(try a.count("outbox") == 0)
        #expect(try a.feed().allSatisfy { !$0.pending })
        #expect(try b.feed().map(\.text) == ["b last", "captured offline", "b first"])
    }

    @Test func aTunnelCaptureReachesAnotherDeviceInTheTunnel() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let b = try Device(server)
        _ = try a.capture("to the tunnel", at: t0, to: .tunnel)
        _ = try a.capture("to the inbox", at: t0 + second)
        try await a.sync()
        try await b.sync()

        #expect(try b.store.items(in: .tunnel, before: nil, limit: 10).map(\.text) == ["to the tunnel"])
        #expect(try b.store.items(in: .inbox, before: nil, limit: 10).map(\.text) == ["to the inbox"])
        #expect(try a.count("outbox") == 0)
    }

    @Test func theTrashAfterCopySettingAndATrashReachAnotherDevice() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let b = try Device(server)
        let id = try a.capture("copy me", at: t0, to: .tunnel)
        try await a.sync()
        try await b.sync()
        #expect(try b.store.trashAfterCopy() == nil)

        try a.store.setTrashAfterCopy(true, nowUs: t0 + second)
        try a.store.trash(itemID: id, nowUs: t0 + second)
        try await a.sync()
        try await b.sync()

        #expect(try a.count("outbox") == 0)
        #expect(a.queued.isEmpty)
        #expect(try b.store.trashAfterCopy() == true)
        #expect(try b.store.items(in: .tunnel, before: nil, limit: 10).isEmpty)

        try b.store.restore(itemID: id, nowUs: t0 + 2 * second)
        try await b.sync()
        try await a.sync()
        #expect(try a.store.items(in: .tunnel, before: nil, limit: 10).map(\.id) == [id])
    }

    @Test func aRepeatedPushChangesNothing() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        _ = try a.capture("once", at: t0)
        let op = try await a.store.pool.read { try String.fetchOne($0, sql: "SELECT op FROM outbox")! }
        _ = try await a.sync()

        try await a.store.pool.write { try $0.execute(sql: "INSERT INTO outbox (op) VALUES (?)", arguments: [op]) }
        _ = try await a.sync()

        let b = try Device(server)
        _ = try await b.sync()
        #expect(try b.feed().map(\.text) == ["once"])
        #expect(try a.count("outbox") == 0)
    }

    @Test func aWrongSecretIsUnauthorized() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server, secret: "not-the-secret")
        _ = try a.capture("kept", at: t0)

        #expect(await a.syncFailure() == .unauthorized)
        #expect(try a.count("outbox") == 1)
    }

    @Test func moreThanABatchPushesAndPullsInPages() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        for i in 0..<501 { _ = try a.capture("item \(i)", at: t0 + Int64(i)) }

        _ = try await a.sync()
        #expect(try a.count("outbox") == 0)

        let b = try Device(server)
        _ = try await b.sync()
        #expect(try b.count("items") == 501)
    }

    @Test func aPulledCaptureKeepsItsExactCaptureTime() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let b = try Device(server)
        let exact = t0 + 123_457

        let id = try a.capture("exact", at: exact)
        _ = try await a.sync()
        _ = try await b.sync()

        for device in [a, b] {
            let stored = try await device.store.pool.read { try Int64.fetchOne($0, sql: "SELECT capture_time FROM items WHERE id = ?", arguments: [id]) }
            #expect(stored == exact)
        }
    }

    @Test func aPulledCaptureKeepsItsExactCaptureTimeWhenTheServerTrimsTheFraction() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let b = try Device(server)
        let times = [t0 + 500_000, t0 + 120_000, t0 + 7 * second]

        let ids = try times.map { try a.capture("at \($0)", at: $0) }
        try await a.sync()
        try await b.sync()

        let stored = try await b.store.pool.read { db in
            try ids.map { try Int64.fetchOne(db, sql: "SELECT capture_time FROM items WHERE id = ?", arguments: [$0]) }
        }
        #expect(stored == times)
    }

    @Test func aCaptureIntoATopicArchivedElsewhereLandsInTheInboxWithANotice() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let gym = newID()
        let elsewhere = newID()

        try await server.push(device: elsewhere, ops: [
            ["id": newID(), "type": "CreateTopic", "at": Time.rfc3339(t0), "topic_id": gym, "name": "Gym"]
        ])
        _ = try await a.sync()
        try await server.push(device: elsewhere, ops: [
            ["id": newID(), "type": "ArchiveTopic", "at": Time.rfc3339(t0 + 10 * second), "topic_id": gym]
        ])

        let id = try a.capture("squat 100", at: t0 + 20 * second, to: .topic(gym))
        try await a.sync()

        #expect(a.queued == [SyncNotice(itemID: id, label: "squat 100", topicName: "Gym", topicID: gym, topicState: .archived)])
        #expect(try a.feed().map(\.topicID) == [nil])
    }

    @Test func aNewServerReceivesAPendingCapture() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(url: "http://127.0.0.1:9", secret: server.secret)
        let missing = newID()
        let id = try a.capture("travels along", at: t0, to: .topic(missing))

        try a.store.saveSettings(url: server.url, newSecret: server.secret, secrets: a.secrets)
        try await a.sync()

        #expect(a.queued == [SyncNotice(itemID: id, label: "travels along", topicName: nil, topicID: missing, topicState: nil)])
        let b = try Device(server)
        _ = try await b.sync()
        #expect(try b.feed().map(\.text) == ["travels along"])
        #expect(try b.feed().map(\.topicID) == [nil])
    }
}

extension TopicTrashTests {
    @Test func aNewServerReceivesAnOfflineTopicWithItsItems() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(url: "http://127.0.0.1:9", secret: server.secret)
        let topic = try a.store.createTopic(name: "Offline", nowUs: t0)
        let id = try a.capture("kept together", at: t0 + 1, to: .topic(topic))

        try a.store.saveSettings(url: server.url, newSecret: server.secret, secrets: a.secrets)
        try await a.sync()

        #expect(a.queued.isEmpty)
        let b = try Device(server)
        _ = try await b.sync()
        #expect(try b.store.places().topics.map(\.name) == ["Offline"])
        #expect(try b.store.items(in: .topic(topic), before: nil, limit: 10).map(\.id) == [id])
    }
}

private final class PullSwitch: Sendable {
    let on = Mutex(false)
}

struct FakeServerCycleTests {
    private static let emptyPage = #"{"items":[],"topics":[],"tombstones":[],"cursor":0,"has_more":false,"settings":{"trash_after_copy":null}}"#

    private static func answerEveryOp(_ request: FakeServer.Request, status: String, reason: String) -> FakeServer.Response {
        let ops = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["ops"] as? [[String: Any]] ?? []
        let results = ops.map { #"{"op_id":"\#($0["id"] as! String)","status":"\#(status)","reason":"\#(reason)","text":null}"# }
        return .json(#"{"results":[\#(results.joined(separator: ","))]}"#)
    }

    private func syncError(_ device: Device, _ id: String) throws -> String? {
        try device.store.pool.read { try String.fetchOne($0, sql: "SELECT sync_error FROM items WHERE id = ?", arguments: [id]) }
    }

    @Test(arguments: ["not_found", "empty", "topic_unavailable", "invalid"])
    func rejectedOperationsUseDesktopClassificationAndPreserveLabels(_ reason: String) async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/push" ? Self.answerEveryOp(request, status: "rejected", reason: reason) : .json(Self.emptyPage)
        }
        let a = try Device(url: fake.url, secret: "secret")
        let id = try a.capture("named Item", at: t0)
        let store = a.store
        try await store.pool.write { db in
            try db.execute(sql: "DELETE FROM outbox")
            for type in ["AddAttachment", "RemoveAttachment", "SetText", "MoveItem", "TrashItem", "RestoreItem"] {
                try store.queue(db, type, nowUs: t0, ["item_id": id])
            }
        }
        try await a.sync()
        let expected: [SyncNotice.Kind] = switch reason {
        case "not_found": [.gone, .failed, .gone, .gone, .gone, .gone]
        case "empty": [.failed, .failed, .failed, .failed, .failed, .empty]
        case "topic_unavailable": [.failed, .failed, .failed, .move, .failed, .failed]
        default: Array(repeating: .failed, count: 6)
        }
        #expect(a.queued.map(\.kind) == expected)
        #expect(a.queued.allSatisfy { $0.label == "named Item" })
    }

    @Test func rejectedOperationsOnRefusedCapturesAreSilent() async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/push" ? Self.answerEveryOp(request, status: "rejected", reason: "invalid") : .json(Self.emptyPage)
        }
        let a = try Device(url: fake.url, secret: "secret")
        let id = try a.capture("refused", at: t0)
        try a.store.editText(itemID: id, text: "changed", baseRev: 0, nowUs: t0 + second)
        try await a.sync()
        #expect(a.queued.isEmpty)
        #expect(try syncError(a, id) == "invalid")
    }

    @Test func aRefusedCaptureIsMarked() async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/push" ? Self.answerEveryOp(request, status: "rejected", reason: "invalid") : .json(Self.emptyPage)
        }
        let a = try Device(url: fake.url, secret: "secret")
        let id = try a.capture("refused", at: t0)

        _ = try await a.sync()

        #expect(try syncError(a, id) == "invalid")
        #expect(try a.feed().map(\.pending) == [false])
        #expect(try a.count("outbox") == 0)
        #expect(fake.requests(to: "/sync/pull") == 1)
    }

    private static func pushIDs(_ request: FakeServer.Request) -> [String] {
        let ops = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["ops"] as? [[String: Any]] ?? []
        return ops.map { $0["id"] as! String }
    }

    private static func answerWithIDs(_ ids: [String]) -> FakeServer.Response {
        .json(#"{"results":[\#(ids.map { #"{"op_id":"\#($0)","status":"accepted","reason":null,"text":null}"# }.joined(separator: ","))]}"#)
    }

    @Test func aPushAnsweredWithAWrongOpIDKeepsTheOps() async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/push" ? Self.answerWithIDs([UUID().uuidString.lowercased()]) : .json(Self.emptyPage)
        }
        let a = try Device(url: fake.url, secret: "secret")
        _ = try a.capture("unanswered", at: t0)

        let failure = await a.syncFailure()

        #expect(failure == .failed("the Server's answer couldn't be read"))
        #expect(try a.count("outbox") == 1)
        #expect(try a.feed().map(\.pending) == [true])
        #expect(fake.requests(to: "/sync/pull") == 0)
    }

    @Test func aPushAnsweredWithADuplicateOpIDKeepsTheOps() async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/push" ? Self.answerWithIDs(Array(repeating: Self.pushIDs(request)[0], count: 2)) : .json(Self.emptyPage)
        }
        let a = try Device(url: fake.url, secret: "secret")
        _ = try a.capture("first", at: t0)
        _ = try a.capture("second", at: t0 + second)

        let failure = await a.syncFailure()

        #expect(failure == .failed("the Server's answer couldn't be read"))
        #expect(try a.count("outbox") == 2)
        #expect(try a.feed().map(\.pending) == [true, true])
        #expect(fake.requests(to: "/sync/pull") == 0)
    }

    @Test func aPullThatHasMoreWithoutAdvancingTheCursorFailsAfterBoundedRequests() async throws {
        let pulls = Mutex(0)
        let fake = try await FakeServer { _ in
            let n = pulls.withLock { $0 += 1; return $0 }
            return .json(#"{"items":[],"topics":[],"tombstones":[],"cursor":0,"has_more":\#(n <= 20),"settings":{"trash_after_copy":null}}"#)
        }
        let a = try Device(url: fake.url, secret: "secret")

        let failure = await a.syncFailure()

        #expect(failure == .failed("the Server's answer couldn't be read"))
        #expect(fake.requests(to: "/sync/pull") == 1)
    }

    @Test func resultsAreKeptWhenThePullFails() async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/push" ? Self.answerEveryOp(request, status: "rejected", reason: "invalid") : .json("{}", status: 500)
        }
        let a = try Device(url: fake.url, secret: "secret")
        let id = try a.capture("refused", at: t0)

        let failure = await a.syncFailure()

        guard case .failed = failure else {
            Issue.record("expected .failed, got \(String(describing: failure))")
            return
        }
        #expect(try syncError(a, id) == "invalid")
        #expect(try a.count("outbox") == 0)
        #expect(fake.requests(to: "/sync/push") == 1)
    }

    @Test func noticesSurviveAFailedPullAndAreCompletedByTheNext() async throws {
        let a = try Device(url: "http://127.0.0.1:9", secret: "secret")
        let gym = newID()
        let pullFails = PullSwitch()
        let archived = #"{"id":"\#(gym)","name":"Gym","archived_at":"2025-10-09T08:53:20Z","deleted_at":null}"#
        let fake = try await FakeServer { request in
            if request.path == "/sync/push" { return Self.answerEveryOp(request, status: "changed", reason: "sent_to_inbox") }
            return pullFails.on.withLock { $0 }
                ? .json("{}", status: 500)
                : .json(#"{"items":[],"topics":[\#(archived)],"tombstones":[],"cursor":1,"has_more":false,"settings":{"trash_after_copy":null}}"#)
        }
        try a.store.saveSettings(url: fake.url, newSecret: "secret", secrets: a.secrets)
        try await a.store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name) VALUES (?, 'Gym')", arguments: [gym]) }
        let id = try a.capture("squat 100", at: t0, to: .topic(gym))

        pullFails.on.withLock { $0 = true }
        let failure = await a.syncFailure()
        guard case .failed = failure else {
            Issue.record("expected .failed, got \(String(describing: failure))")
            return
        }
        #expect(a.queued == [SyncNotice(itemID: id, label: "squat 100", topicName: "Gym", topicID: gym, topicState: nil)])

        pullFails.on.withLock { $0 = false }
        try await a.sync()
        #expect(a.queued == [SyncNotice(itemID: id, label: "squat 100", topicName: "Gym", topicID: gym, topicState: .archived)])
        #expect(fake.requests(to: "/sync/push") == 1)
    }

    @Test func aTransportFailureNamesNeitherTheHostNorThePort() async throws {
        let fake = try await FakeServer { _ in .json(Self.emptyPage) }
        let port = String(fake.url.split(separator: ":").last!)
        let a = try Device(url: "https://127.0.0.1:\(port)", secret: "secret")

        let failure = await a.syncFailure()

        #expect(failure == .failed("couldn't make a secure connection to the Server"))
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let fake = try await FakeServer { request in
            request.path == "/sync/pull"
                ? FakeServer.Response(status: 302, headers: ["Location": "/elsewhere"])
                : .json(Self.emptyPage)
        }
        let a = try Device(url: fake.url, secret: "secret")

        let failure = await a.syncFailure()

        guard case .failed = failure else {
            Issue.record("expected .failed, got \(String(describing: failure))")
            return
        }
        #expect(fake.requests(to: "/sync/pull") == 1)
        #expect(fake.requests(to: "/elsewhere") == 0)
    }

    @Test func aCycleStartedBeforeAURLChangeWritesNothing() async throws {
        let a = try Device(url: "http://127.0.0.1:9", secret: "secret")
        let pulled = #"{"id":"\#(newID())","topic_id":null,"text":"from the old Server","capture_time":"2025-10-09T08:53:20Z","deleted_at":null,"purge_at":null,"text_rev":0,"tunnel":false,"attachments":[]}"#
        let store = a.store
        let secrets = a.secrets
        let fake = try await FakeServer { request in
            try? store.saveSettings(url: "http://127.0.0.1:10", newSecret: "other", secrets: secrets)
            return .json(#"{"items":[\#(pulled)],"topics":[],"tombstones":[],"cursor":5,"has_more":\#(request.query == "cursor=0"),"settings":{"trash_after_copy":null}}"#)
        }
        try a.store.saveSettings(url: fake.url, newSecret: "secret", secrets: a.secrets)

        let changed = try await a.sync()

        #expect(changed == false)
        #expect(a.queued.isEmpty)
        #expect(try a.count("items") == 0)
        #expect(try a.cursor() == 0)
        #expect(fake.requests(to: "/sync/pull") == 1)
    }

    @Test func aCycleStartedBeforeAURLChangeLeavesItsPushResultsUnapplied() async throws {
        let a = try Device(url: "http://127.0.0.1:9", secret: "secret")
        let store = a.store
        let secrets = a.secrets
        let fake = try await FakeServer { request in
            try? store.saveSettings(url: "http://127.0.0.1:10", newSecret: "other", secrets: secrets)
            return request.path == "/sync/push" ? Self.answerEveryOp(request, status: "rejected", reason: "invalid") : .json(Self.emptyPage)
        }
        try a.store.saveSettings(url: fake.url, newSecret: "secret", secrets: a.secrets)
        let id = try a.capture("pending", at: t0)

        let changed = try await a.sync()

        #expect(changed == false)
        #expect(a.queued.isEmpty)
        #expect(try a.count("outbox") == 1)
        #expect(try syncError(a, id) == nil)
        #expect(try a.feed().map(\.pending) == [true])
        #expect(fake.requests(to: "/sync/pull") == 0)
    }
}

extension ServerCycleTests {
    @Test func offlineEditsAndMovesSyncAndConflictsPreserveBothTexts() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let b = try Device(server)
        let id = try a.capture("original", at: t0)
        try await a.sync()
        try await b.sync()
        let base = try b.feed()[0].editBase
        #expect(try !b.store.editText(itemID: id, text: "mine", baseRev: base, nowUs: t0 + second))
        #expect(try !a.store.editText(itemID: id, text: "theirs", baseRev: base, nowUs: t0 + 2 * second))
        try a.store.move(itemID: id, to: .tunnel, nowUs: t0 + 2 * second)
        try await a.sync()
        try await b.sync()
        let conflicted = try #require(b.feed().first)
        #expect(conflicted.text == "theirs")
        #expect(conflicted.conflict?.text == "mine")
        #expect(conflicted.conflict?.mine == true)
        #expect(conflicted.inTunnel)
        #expect(try !b.store.resolveTextConflict(itemID: id, keepMine: true, nowUs: t0 + 3 * second))
        try await b.sync()
        try await a.sync()
        #expect(try a.feed()[0].text == "mine")
        #expect(try b.feed()[0].conflict == nil)
    }
}

extension ServerCycleTests {
    @Test func overwritingAnOfflineEditPreservesTheReplacedServerText() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let b = try Device(server)
        let id = try a.capture("original", at: t0)
        try await a.sync()
        try await b.sync()
        let base = try b.feed()[0].editBase
        try a.store.editText(itemID: id, text: "older", baseRev: base, nowUs: t0 + second)
        try b.store.editText(itemID: id, text: "newer", baseRev: base, nowUs: t0 + 2 * second)
        try await a.sync()
        try await b.sync()
        #expect(try b.feed()[0].text == "newer")
        #expect(try b.feed()[0].conflict?.text == "older")
        #expect(try b.feed()[0].conflict?.mine == false)
        try b.store.resolveTextConflict(itemID: id, keepMine: false, nowUs: t0 + 3 * second)
        try await b.sync()
        try await a.sync()
        #expect(try a.feed()[0].text == "older")
    }

    @Test func aRefusedMoveIsReportedAndReturnsToTheServerPlace() async throws {
        let server = try TestServer()
        try await server.start()
        let a = try Device(server)
        let topic = newID()
        let remote = newID()
        try await server.push(device: remote, ops: [["id": newID(), "type": "CreateTopic", "at": Time.rfc3339(t0), "topic_id": topic, "name": "Gym"]])
        let id = try a.capture("move", at: t0, to: .tunnel)
        try await a.sync()
        try a.store.move(itemID: id, to: .topic(topic), nowUs: t0 + second)
        try await server.push(device: remote, ops: [["id": newID(), "type": "ArchiveTopic", "at": Time.rfc3339(t0 + 2 * second), "topic_id": topic]])
        try await a.sync()
        #expect(a.queued.last?.kind == .move)
        #expect(try a.feed()[0].inTunnel)
    }
}
