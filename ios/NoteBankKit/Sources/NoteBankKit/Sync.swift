import Foundation
import GRDB
import Network
import os

private let logger = Logger(subsystem: "app.notebank.ios", category: "sync")

public enum SyncFailure: Error, Equatable {
    case notConfigured, unauthorized, keychain(String), failed(String)
}

public struct SyncNotice: Equatable, Sendable {
    public enum Kind: Sendable { case inbox, move, gone, empty, failed }
    public internal(set) var kind: Kind = .inbox

    public enum TopicState: String, Sendable {
        case archived, deleted
    }

    public let itemID: String
    public let label: String
    public let topicName: String?
    let topicID: String?
    public internal(set) var topicState: TopicState?

    public var message: String {
        switch kind {
        case .gone: return "Couldn't save your change: this Item was deleted for good on another Device."
        case .empty: return "Couldn't restore this Item: it has no text or files left."
        case .failed: return "The Server refused this change. Its version will be restored when sync completes."
        case .move: return "Couldn't move this Item: its destination was archived or deleted on another Device."
        case .inbox: break
        }
        guard let topicName, let topicState else { return #"Saved "\#(label)" to the Inbox: its Topic isn't on this Server."# }
        return #"Saved "\#(label)" to the Inbox: \#(topicName) was \#(topicState.rawValue) on another Device."#
    }
}

func label(text: String?, firstFilename: String?) -> String {
    let line = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !line.isEmpty else { return firstFilename ?? "" }
    return line.count > 40 ? String(line.prefix(40)) + "…" : line
}

public final class SyncHTTP: NSObject, Sendable, URLSessionTaskDelegate {
    public static let live = SyncHTTP()

    private static let timeoutSeconds: TimeInterval = 30
    let session: URLSession

    private override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        session = URLSession(configuration: configuration)
        super.init()
    }

    func send(_ serverURL: String, path: String, secret: String, body: Data? = nil) async throws(SyncFailure) -> Data {
        guard let url = URL(string: serverURL + path) else { throw .failed("the Server URL can't be used") }
        var request = URLRequest(url: url, timeoutInterval: Self.timeoutSeconds)
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: self) } catch {
            // URLError's own text can name the host, so only these fixed strings leave here.
            switch (error as? URLError)?.code {
            case .timedOut: throw .failed("the Server took too long to answer")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                throw .failed("couldn't make a secure connection to the Server")
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed:
                throw .failed("couldn't reach the Server")
            default: throw .failed("the request failed")
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw .unauthorized
        default:
            logger.error("HTTP status \(status, privacy: .public)")
            throw .failed("the Server answered \(status)")
        }
    }

    // A redirect must not carry the secret to another host.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

private struct PushResponse: Decodable {
    struct Result: Decodable {
        let opID: String
        let status: String
        let reason: String?
        let text: String?

        enum CodingKeys: String, CodingKey {
            case status, reason, text
            case opID = "op_id"
        }
    }

    let results: [Result]
}

private let maxPushOps = 500

/// Returns whether anything changed. A Notice stays in `queued` until the caller publishes and clears it, so a failed pull loses none.
public func cycle(store: Store, secrets: SecretStore, http: SyncHTTP, queued: inout [SyncNotice]) async throws(SyncFailure) -> Bool {
    do {
        guard let url = try store.serverURL() else { throw SyncFailure.notConfigured }
        let secret: String?
        do { secret = try secrets.read() } catch { throw SyncFailure.keychain(error.localizedDescription) }
        guard let secret else { throw SyncFailure.notConfigured }
        let deviceID = try store.deviceID()

        var changed = false
        while true {
            let batch = try await store.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT seq, op FROM outbox ORDER BY seq LIMIT ?", arguments: [maxPushOps]).map { ($0["seq"] as Int64, $0["op"] as String) }
            }
            guard let lastSeq = batch.last?.0 else { break }
            let ops = try batch.map { _, json -> [String: Any] in
                guard let op = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], op["id"] is String else {
                    throw SyncFailure.failed("an unreadable operation in the outbox")
                }
                return op
            }
            let pushed = Dictionary(
                ops.map { ($0["id"] as? String ?? "", (type: $0["type"] as? String, itemID: $0["item_id"] as? String, topicID: $0["topic_id"] as? String, text: $0["text"] as? String)) },
                uniquingKeysWith: { first, _ in first })
            let body = try JSONSerialization.data(withJSONObject: ["device_id": deviceID, "ops": ops], options: [.withoutEscapingSlashes])
            let answer = try await http.send(url, path: "/sync/push", secret: secret, body: body)
            guard let response = try? JSONDecoder().decode(PushResponse.self, from: answer),
                response.results.count == ops.count, Set(response.results.map(\.opID)) == Set(pushed.keys)
            else {
                throw SyncFailure.failed("the Server's answer couldn't be read")
            }

            let results = try await store.pool.write { db -> [SyncNotice]? in
                guard try Bool.fetchOne(db, sql: "SELECT server_url = ? FROM device", arguments: [url]) == true else { return nil }
                var notices: [SyncNotice] = []
                for result in response.results {
                    guard let op = pushed[result.opID] else { continue }
                    switch (result.status, op.type, op.itemID, result.reason) {
                    case ("rejected", "CaptureItem", let itemID?, let reason):
                        try db.execute(sql: "UPDATE items SET sync_error = ? WHERE id = ?", arguments: [reason ?? "unknown", itemID])
                    case ("changed", "CaptureItem", let itemID?, "sent_to_inbox"):
                        let text = try String.fetchOne(db, sql: "SELECT text FROM items WHERE id = ?", arguments: [itemID])
                        let filename = try String.fetchOne(db, sql: "SELECT filename FROM attachments WHERE item_id = ? ORDER BY rowid LIMIT 1", arguments: [itemID])
                        let topicName = try op.topicID.flatMap { try String.fetchOne(db, sql: "SELECT name FROM topics WHERE id = ?", arguments: [$0]) }
                        notices.append(SyncNotice(itemID: itemID, label: label(text: text, firstFilename: filename), topicName: topicName, topicID: op.topicID))
                    case ("rejected", "SetText", let itemID?, "superseded"), ("changed", "SetText", let itemID?, "overwrote"):
                        let mine = result.status == "rejected"
                        try db.execute(sql: """
                            INSERT INTO conflicts(item_id, text, mine) SELECT ?, ?, ? WHERE EXISTS(SELECT 1 FROM items WHERE id = ?)
                            ON CONFLICT(item_id) DO UPDATE SET text = excluded.text, mine = excluded.mine
                            """, arguments: [itemID, mine ? op.text : result.text, mine, itemID])
                    case ("rejected", let type?, let itemID?, let reason) where ["MoveItem", "SetText", "TrashItem", "RestoreItem"].contains(type):
                        var notice = SyncNotice(itemID: itemID, label: "", topicName: nil, topicID: op.topicID)
                        notice.kind = reason == "not_found" ? .gone : reason == "topic_unavailable" ? .move : reason == "empty" ? .empty : .failed
                        notices.append(notice)
                    case ("accepted", _, _, _):
                        break
                    default:
                        logger.info("op \(result.opID, privacy: .public) \(result.status, privacy: .public): \(result.reason ?? "", privacy: .public)")
                    }
                }
                // Each pushed op was answered exactly once, so all of them leave the outbox; pull brings the Server's version.
                try db.execute(sql: "DELETE FROM outbox WHERE seq <= ?", arguments: [lastSeq])
                return notices
            }
            guard let results else { return false }
            queued += results
            changed = true
        }

        while true {
            let cursor = try await store.pool.read { try Int64.fetchOne($0, sql: "SELECT pull_cursor FROM device")! }
            let data = try await http.send(url, path: "/sync/pull?cursor=\(cursor)", secret: secret)
            guard let page = try? JSONDecoder().decode(PullPage.self, from: data) else {
                throw SyncFailure.failed("the Server's answer couldn't be read")
            }
            guard !page.hasMore || page.cursor > cursor else { throw SyncFailure.failed("the Server's answer couldn't be read") }
            if try store.applyPull(page, serverURL: url) {
                changed = true
            } else if try store.serverURL() != url {
                return false
            }
            guard page.hasMore else { break }
        }

        let carried = queued
        queued = try await store.pool.read { db in
            try carried.map { item in
                var notice = item
                let state = try item.topicID.flatMap {
                    try String.fetchOne(
                        db,
                        sql: "SELECT CASE WHEN deleted_at IS NOT NULL THEN 'deleted' WHEN archived_at IS NOT NULL THEN 'archived' END FROM topics WHERE id = ?",
                        arguments: [$0])
                }
                notice.topicState = state.flatMap(SyncNotice.TopicState.init(rawValue:))
                return notice
            }
        }
        return changed
    } catch let failure as SyncFailure {
        throw failure
    } catch {
        throw .failed("couldn't use local storage")
    }
}

public enum SyncStatus: Sendable, Equatable {
    case synced, syncing, offline, unauthorized, keychain, notConfigured

    public var label: String {
        switch self {
        case .synced: "Synced"
        case .syncing: "Syncing…"
        case .offline: "Offline, retrying"
        case .unauthorized: "Secret rejected"
        case .keychain: "Keychain access needed"
        case .notConfigured: ""
        }
    }
}

public enum Wait: Equatable, Sendable {
    case after(Duration), untilSettingsSaved, untilWoken
}

private let maxBackoff = Duration.seconds(300)

func outcome(_ result: Result<Bool, SyncFailure>, failures: Int, poll: Duration = SyncEngine.defaultPollInterval) -> (SyncStatus, Wait) {
    switch result {
    case .success: (.synced, .after(poll))
    case .failure(.failed): (.offline, .after(min(.seconds(1 << min(failures, 9)), maxBackoff)))
    case .failure(.unauthorized): (.unauthorized, .untilSettingsSaved)
    case .failure(.notConfigured): (.notConfigured, .untilSettingsSaved)
    // Retrying on a timer would show the keychain prompt again and again.
    case .failure(.keychain): (.keychain, .untilWoken)
    }
}

public actor SyncEngine {
    public static let defaultPollInterval = Duration.seconds(10)

    public nonisolated let status: AsyncStream<SyncStatus>
    public nonisolated let notices: AsyncStream<[SyncNotice]>
    private let statusSink: AsyncStream<SyncStatus>.Continuation
    private let noticeSink: AsyncStream<[SyncNotice]>.Continuation
    private let store: Store
    private let secrets: SecretStore
    private let http: SyncHTTP
    private let pollInterval: Duration
    private let transfers: AttachmentTransfers?
    private let monitor = NWPathMonitor()

    private var loop: Task<Void, Never>?
    private var flight: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var wait: Wait?
    private var woken = false
    private var saved = false
    private var elapsed = false
    private var background = false
    private var pathSatisfied: Bool?
    private var failures = 0
    private var flush = false
    private var flushed: [CheckedContinuation<Void, Never>] = []
    private var lastStatus: SyncStatus?
    private var queued: [SyncNotice] = []
    private var saves = 0

    public init(store: Store, secrets: SecretStore, http: SyncHTTP = .live, transfers: AttachmentTransfers? = nil, pollInterval: Duration = SyncEngine.defaultPollInterval) {
        self.store = store
        self.secrets = secrets
        self.http = http
        self.transfers = transfers
        self.pollInterval = pollInterval
        (status, statusSink) = AsyncStream.makeStream()
        (notices, noticeSink) = AsyncStream.makeStream()
    }

    public func start() async {
        guard loop == nil else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.notebank.ios.path"))
        if let transfers { await transfers.setWakeHandler { [weak self] in Task { await self?.wake() } } }
        wait = .after(.zero)
        loop = Task {
            while !Task.isCancelled {
                await waitForTrigger()
                let task = Task { await runCycle() }
                flight = task
                await task.value
            }
        }
    }

    public func wake() {
        woken = true
        kick()
    }

    public func settingsSaved() {
        saves += 1
        queued = []
        saved = true
        kick()
    }

    public func enterBackground() async {
        background = true
        if let flight {
            await flight.value
            guard failures == 0 else { return }
        }
        guard await outboxHasOps() else { return }
        if let flight { return await flight.value }
        guard case .after? = wait else { return }
        flush = true
        kick()
        await withCheckedContinuation { flushed.append($0) }
    }

    public func enterForeground() {
        background = false
        wake()
    }

    public func cancelInFlight() {
        flight?.cancel()
    }

    private var triggered: Bool {
        if flush { return true }
        return !background && (saved || elapsed || (woken && wait != .untilSettingsSaved))
    }

    private func kick() {
        guard triggered, let waiter else { return }
        self.waiter = nil
        waiter.resume()
    }

    private func pathChanged(satisfied: Bool) {
        if satisfied && pathSatisfied == false { wake() }
        pathSatisfied = satisfied
    }

    private func elapse() {
        guard !Task.isCancelled else { return }
        elapsed = true
        kick()
    }

    private func waitForTrigger() async {
        if case .after(let duration)? = wait {
            timer = Task {
                try? await Task.sleep(for: duration)
                elapse()
            }
        }
        while !triggered { await withCheckedContinuation { waiter = $0 } }
        timer?.cancel()
        timer = nil
        wait = nil
    }

    private func outboxHasOps() async -> Bool {
        (try? await store.pool.read { try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM outbox)") }) ?? false
    }

    private func emit(_ next: SyncStatus) {
        guard next != lastStatus else { return }
        lastStatus = next
        statusSink.yield(next)
    }

    private func runCycle() async {
        // This cycle reads the current Settings and outbox, so only a signal that arrives from here on is news.
        saved = false
        woken = false
        flush = false
        let generation = saves
        if await outboxHasOps() { emit(.syncing) }

        var carried = queued
        let result: Result<Bool, SyncFailure>
        do throws(SyncFailure) {
            let changed = try await cycle(store: store, secrets: secrets, http: http, queued: &carried)
            if let transfers {
                do { try await transfers.synchronize() }
                catch let failure as SyncFailure { throw failure }
                catch { throw SyncFailure.failed("couldn't schedule attachment uploads") }
            }
            result = .success(changed)
        } catch {
            result = .failure(error)
        }

        queued = generation == saves ? carried : []
        failures = if case .failure(.failed) = result { failures + 1 } else { 0 }
        let (next, following) = outcome(result, failures: failures, poll: pollInterval)
        if case .success = result, !queued.isEmpty {
            noticeSink.yield(queued)
            queued = []
        }
        let pending = (try? store.pendingUploads().isEmpty) == false
        emit(next == .synced && pending ? .syncing : next)
        if case .success = result, !background, let transfers { Task { await transfers.prefetchThumbnails() } }
        wait = following
        elapsed = false
        flight = nil
        for waiter in flushed { waiter.resume() }
        flushed = []
    }
}
