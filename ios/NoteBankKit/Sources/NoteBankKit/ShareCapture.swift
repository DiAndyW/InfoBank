import Foundation
import GRDB
import Observation

@MainActor @Observable
public final class ShareCaptureModel {
    public private(set) var sharedText = ""
    public var extraText = ""
    public var destination = Destination.inbox
    public private(set) var attachments: [StagedAttachment] = []
    public private(set) var topics: [TopicPlace] = []
    public private(set) var error: String?
    public private(set) var savedItemID: String?
    private var imports = 0
    private var importFailed = false
    private let store: Store

    public init(store: Store) {
        self.store = store
        do { topics = try store.places().topics }
        catch { self.error = "Couldn't read Topics; you can still save to Inbox." }
    }

    public var isImporting: Bool { imports > 0 }

    public var canSave: Bool {
        savedItemID == nil && imports == 0 && !importFailed &&
        (!sharedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
         !extraText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    public func beginImport() { imports += 1 }
    public func endImport() { imports = max(0, imports - 1) }
    public func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        sharedText += (sharedText.isEmpty ? "" : "\n\n") + text
    }
    public func addAttachment(_ file: StagedAttachment) { attachments.append(file) }
    public func reportImportError() {
        importFailed = true
        error = "Couldn't load everything that was shared. Cancel and try sharing again."
    }

    public func save() -> String? {
        if let savedItemID { return savedItemID }
        guard canSave else { return nil }
        let text = [sharedText, extraText].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        do {
            let id = try store.capture(text: text, attachmentIDs: attachments.map(\.id), to: destination, nowUs: Time.nowUs())
            savedItemID = id
            attachments = []
            error = nil
            return id
        } catch { self.error = error.localizedDescription; return nil }
    }

    public func cancel() {
        guard savedItemID == nil else { return }
        for file in attachments { try? store.discardStaged(file.id) }
        attachments = []
    }
}

@discardableResult
func pushSharedCapture(_ itemID: String, store: Store, secrets: SecretStore) async throws -> Bool {
    guard let server = try store.serverURL(), let secret = try secrets.read() else { throw SyncFailure.notConfigured }
    let generation = try store.transferGeneration()
    guard let json = try await store.pool.read({ db in
        try String.fetchOne(db, sql: "SELECT op FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem' AND json_extract(op, '$.item_id') = ?", arguments: [itemID])
    }) else {
        if try await store.pool.read({ db in
            try Bool.fetchOne(db, sql: "SELECT sync_error IS NOT NULL FROM items WHERE id = ?", arguments: [itemID])
        }) == true { throw ShareCaptureFailure.refused }
        return false
    }
    guard let op = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let opID = op["id"] as? String else {
        throw SyncFailure.failed("Couldn't read the saved Capture")
    }
    let body = try JSONSerialization.data(withJSONObject: ["device_id": store.deviceID(), "ops": [op]])
    let answer = try await SyncHTTP.live.send(server, path: "/sync/push", secret: secret, body: body, timeoutSeconds: 8)
    struct Response: Decodable {
        struct Result: Decodable {
            let op_id: String
            let status: String
            let reason: String?
        }
        let results: [Result]
    }
    let response = try JSONDecoder().decode(Response.self, from: answer)
    guard response.results.count == 1, let result = response.results.first, result.op_id == opID,
          result.status == "accepted" || result.status == "rejected" || (result.status == "changed" && result.reason == "sent_to_inbox") else {
        throw SyncFailure.failed("Couldn't confirm the Capture")
    }
    try await store.pool.write { db in
        guard try String.fetchOne(db, sql: "SELECT server_url FROM device") == server,
              try Int64.fetchOne(db, sql: "SELECT transfer_generation FROM device") == generation else {
            throw SyncFailure.failed("Server changed; saved locally")
        }
        if result.status == "rejected" {
            try db.execute(sql: "UPDATE items SET sync_error = ? WHERE id = ?", arguments: [result.reason ?? "unknown", itemID])
        } else if result.status == "changed" {
            try db.execute(sql: "UPDATE items SET topic_id = NULL WHERE id = ?", arguments: [itemID])
        }
        try db.execute(sql: "DELETE FROM outbox WHERE json_extract(op, '$.id') = ?", arguments: [opID])
    }
    guard result.status != "rejected" else { throw ShareCaptureFailure.refused }
    return result.status == "changed"
}

public enum ShareDelivery: Sendable, Equatable {
    case sent, sentToInbox, savedLocally, refused
}

private enum ShareCaptureFailure: Error {
    case refused
}

public func deliverSharedCapture(_ itemID: String, store: Store, secrets: SecretStore, transfers: AttachmentTransfers, timeout: Duration = .seconds(8)) async -> ShareDelivery {
    await withTaskGroup(of: ShareDelivery.self) { group in
        group.addTask {
            do {
                let inbox = try await pushSharedCapture(itemID, store: store, secrets: secrets)
                try Task.checkCancellation()
                try await transfers.synchronize(itemID: itemID)
                return inbox ? .sentToInbox : .sent
            } catch ShareCaptureFailure.refused { return .refused }
            catch { return .savedLocally }
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return .savedLocally
        }
        let result = await group.next() ?? .savedLocally
        group.cancelAll()
        return result
    }
}
