import Foundation
import GRDB
import Synchronization
import Testing
@testable import NoteBankKit

struct SettingsTests {
    private let enterURL = SettingsError(message: "Enter the Server URL, starting with https://")
    private let needsHTTPS = SettingsError(message: "The Server URL must start with https://")
    private let noUserinfo = SettingsError(message: "The Server URL can't include a user name, query or fragment")

    private func cursor(_ store: Store) throws -> Int64 {
        try store.pool.read { try Int64.fetchOne($0, sql: "SELECT pull_cursor FROM device")! }
    }

    private func count(_ store: Store, _ table: String) throws -> Int {
        try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)")! }
    }

    @Test func urlValidationTable() throws {
        let accepted = [
            ("https://notes.example.com", "https://notes.example.com"),
            ("https://notes.example.com/", "https://notes.example.com"),
            ("  https://notes.example.com/  ", "https://notes.example.com"),
            ("HTTPS://Notes.Example.com", "https://notes.example.com"),
            ("http://localhost:8080", "http://localhost:8080"),
            ("http://127.0.0.1:8080", "http://127.0.0.1:8080"),
        ]
        for (input, stored) in accepted {
            let (store, _) = try tempStore()
            try store.saveSettings(url: input, newSecret: "s3cret", secrets: .memory())
            #expect(try store.serverURL() == stored, "input \(input)")
        }
        let rejected = [
            ("http://notes.example.com", needsHTTPS), ("ftp://x", needsHTTPS),
            ("garbage", enterURL), ("", enterURL), ("https://a%20b.com", enterURL), ("https://x.com%2Fevil", enterURL),
            ("https://user:pw@x.com", noUserinfo), ("https://x.com/?a=1", noUserinfo), ("https://x.com/#f", noUserinfo),
        ]
        for (input, error) in rejected {
            let (store, _) = try tempStore()
            #expect(throws: error, "input \(input)") { try store.saveSettings(url: input, newSecret: "s3cret", secrets: .memory()) }
            #expect(try store.serverURL() == nil, "input \(input) was stored")
        }
    }

    @Test func aBlankSecretIsRefused() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        #expect(throws: SettingsError(message: "The secret can't be blank")) {
            try store.saveSettings(url: "https://notes.example.com", newSecret: " \n ", secrets: secrets)
        }
        #expect(try store.serverURL() == nil)
        #expect(try secrets.read() == nil)
    }

    @Test func theSecretIsSavedTrimmed() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://notes.example.com", newSecret: "  s3cret\n", secrets: secrets)
        #expect(try secrets.read() == "s3cret")
    }

    @Test func noSecretGivenNeedsASavedOneAndTheSameURL() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        #expect(throws: SettingsError(message: "Enter the shared secret")) {
            try store.saveSettings(url: "https://a.example.com", newSecret: nil, secrets: secrets)
        }
        #expect(try store.serverURL() == nil)

        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        try store.saveSettings(url: "https://a.example.com/", newSecret: nil, secrets: secrets)
        #expect(try secrets.read() == "s3cret")

        #expect(throws: SettingsError(message: "Enter the secret again for a new Server")) {
            try store.saveSettings(url: "https://b.example.com", newSecret: nil, secrets: secrets)
        }
        #expect(try store.serverURL() == "https://a.example.com")
    }

    @Test func theSecretIsWrittenBeforeTheURL() throws {
        let (store, _) = try tempStore()
        let failing = SecretStore(
            read: { nil },
            write: { _ in throw KeychainError(status: errSecInteractionNotAllowed) })
        #expect(throws: SettingsError.self) {
            try store.saveSettings(url: "https://notes.example.com", newSecret: "s3cret", secrets: failing)
        }
        #expect(try store.serverURL() == nil)
    }

    @Test func aKeychainWriteFailureIsReportedWithItsDetail() throws {
        let (store, _) = try tempStore()
        let failing = SecretStore(read: { nil }, write: { _ in throw KeychainError(status: errSecInteractionNotAllowed) })
        let detail = try #require(KeychainError(status: errSecInteractionNotAllowed).errorDescription)
        #expect(throws: SettingsError(message: "Couldn't save to the keychain: \(detail)")) {
            try store.saveSettings(url: "https://notes.example.com", newSecret: "s3cret", secrets: failing)
        }
    }

    @Test func aKeychainReadFailureIsReportedWithItsDetail() throws {
        let (store, _) = try tempStore()
        let failing = SecretStore(read: { throw KeychainError(status: errSecInteractionNotAllowed) }, write: { _ in })
        let detail = try #require(KeychainError(status: errSecInteractionNotAllowed).errorDescription)
        #expect(throws: SettingsError(message: "Couldn't read the keychain: \(detail)")) { try store.settings(secrets: failing) }
    }

    @Test func aNewURLClearsTheMirrorButKeepsPendingCaptures() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        let pending = try store.capture(text: "unsynced", to: .topic("old"), nowUs: 2)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1)")
            try db.execute(sql: "INSERT INTO topics (id, name) VALUES ('old', 'Old')")
            try db.execute(sql: "UPDATE device SET pull_cursor = 42")
        }

        try store.saveSettings(url: "https://b.example.com", newSecret: "s3cret", secrets: secrets)

        #expect(try store.pool.read { try String.fetchAll($0, sql: "SELECT id FROM items") } == [pending])
        #expect(try count(store, "topics") == 0)
        #expect(try count(store, "outbox") == 1)
        #expect(try cursor(store) == 0)
        #expect(try store.serverURL() == "https://b.example.com")
    }

    @Test func aNewURLKeepsTopicsCreatedOffline() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        let topic = try store.createTopic(name: "Offline", nowUs: 1)
        let pending = try store.capture(text: "unsynced", to: .topic(topic), nowUs: 2)
        try store.pool.write { db in try db.execute(sql: "INSERT INTO topics (id, name) VALUES ('old', 'Old')") }

        try store.saveSettings(url: "https://b.example.com", newSecret: "s3cret", secrets: secrets)

        #expect(try store.places().topics.map(\.name) == ["Offline"])
        #expect(try store.items(in: .topic(topic), before: nil, limit: 10).map(\.id) == [pending])
    }

    @Test func theSameURLKeepsTheCursor() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1)")
            try db.execute(sql: "INSERT INTO topics (id, name) VALUES ('t', 'T')")
            try db.execute(sql: "UPDATE device SET pull_cursor = 42")
        }

        try store.saveSettings(url: "https://a.example.com/", newSecret: nil, secrets: secrets)
        try store.saveSettings(url: "https://a.example.com", newSecret: "other", secrets: secrets)

        #expect(try cursor(store) == 42)
        #expect(try count(store, "items") == 1)
        #expect(try count(store, "topics") == 1)
    }

    @Test func settingsNeverReturnTheSecret() throws {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        #expect(try store.settings(secrets: secrets) == SettingsState(serverURL: nil, hasSecret: false))
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        let state = try store.settings(secrets: secrets)
        #expect(state == SettingsState(serverURL: "https://a.example.com", hasSecret: true))
        #expect(!"\(state)".contains("s3cret"))
    }

    private func outboxTypes(_ store: Store) throws -> [String] {
        try store.pool.read { try String.fetchAll($0, sql: "SELECT json_extract(op, '$.type') FROM outbox ORDER BY seq") }
    }

    // Connected to A, with a pulled Item "pulled" that has one unuploaded file and a pulled Topic "old".
    private func connectedToA() throws -> (store: Store, secrets: SecretStore) {
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1)")
            try db.execute(sql: "INSERT INTO topics (id, name) VALUES ('old', 'Old')")
            try db.execute(sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES ('f1', 'pulled', 'f.png', 'image/png', 1, 0, 0)")
        }
        return (store, secrets)
    }

    private func stranded(_ body: () throws -> Void) -> SettingsError? {
        do { try body() } catch let error as SettingsError { return error } catch {}
        return nil
    }

    private func check(_ url: String, _ secret: String) async -> SettingsError? {
        do throws(SettingsError) { try await ServerCheck.live.run(url, secret) } catch { return error }
        return nil
    }

    @Test func checkAcceptsTheRightSecret() async throws {
        let server = try TestServer(); try await server.start()
        #expect(await check(server.url, server.secret) == nil)
    }

    @Test func checkRejectsAWrongSecret() async throws {
        let server = try TestServer(); try await server.start()
        #expect(await check(server.url, "wrong") == SettingsError(message: "The Server rejected this secret."))
    }

    @Test func checkAfterTenFailuresSaysWhenToRetry() async throws {
        let server = try TestServer(); try await server.start()
        for _ in 0..<10 { _ = await check(server.url, "wrong") }
        #expect(await check(server.url, server.secret) == SettingsError(message: "Too many failed attempts. Try again in 15 minutes."))
    }

    @Test func checkUnreachable() async {
        #expect(await check("http://127.0.0.1:1", "s") == SettingsError(message: "Couldn't reach the Server."))
    }

    @Test func checkOtherStatusesAndRetryAfterWording() async throws {
        let cases: [(FakeServer.Response, String)] = [
            (.init(status: 502), "Couldn't check the Server: it answered 502."),
            (.init(status: 302, headers: ["Location": "http://127.0.0.1:1/"]), "Couldn't check the Server: it answered 302."),
            (.init(status: 429, headers: ["Retry-After": "60"]), "Too many failed attempts. Try again in 1 minute."),
            (.init(status: 429, headers: ["Retry-After": "61"]), "Too many failed attempts. Try again in 2 minutes."),
            (.init(status: 429, headers: ["Retry-After": "18446744073709551615"]), "Too many failed attempts. Try again in 307445734561825861 minutes."),
            (.init(status: 429), "Too many failed attempts. Try again later."),
            (.init(status: 429, headers: ["Retry-After": "soon"]), "Too many failed attempts. Try again later."),
        ]
        for (response, message) in cases {
            let server = try await FakeServer { _ in response }
            #expect(await check(server.url, "s") == SettingsError(message: message), "\(response.status)")
        }
    }

    @Test func aSyncedItemWithAnUnuploadedFileBlocks() throws {
        let (store, secrets) = try connectedToA()
        try store.pool.write { try $0.execute(sql: "UPDATE device SET pull_cursor = 7") }
        let error = stranded { try store.saveSettings(url: "https://b.example.com", newSecret: "new", secrets: secrets) }
        #expect(error == SettingsError(
            message: "1 file hasn't reached the current Server yet. Switching discards this work for good.",
            stranded: Stranded(changes: 0, files: 1)))
        #expect(try count(store, "items") == 1)
        #expect(try cursor(store) == 7)
        #expect(try store.serverURL() == "https://a.example.com")
        #expect(try secrets.read() == "s3cret")
    }

    @Test func pendingChangesOnSyncedRowsBlock() throws {
        let (store, secrets) = try connectedToA()
        try store.pool.write { try $0.execute(sql: "UPDATE attachments SET uploaded = 1") }
        try store.editText(itemID: "pulled", text: "y", baseRev: 0, nowUs: 2)
        try store.trash(itemID: "pulled", nowUs: 3)
        try store.renameTopic("old", name: "New", nowUs: 4)
        let error = stranded { try store.saveSettings(url: "https://b.example.com", newSecret: "new", secrets: secrets) }
        #expect(error?.stranded == Stranded(changes: 3, files: 0))
        #expect(error?.message.hasPrefix("3 changes haven't") == true)
        #expect(try count(store, "outbox") == 3)
    }

    @Test func aKeptCaptureWithAnUnuploadedFileDoesNotBlockAndStillUploads() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: secrets)
        let staged = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "kept", attachmentIDs: [staged.id], to: .inbox, nowUs: 1_760_000_000_000_000)

        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        var notices: [SyncNotice] = []
        _ = try await cycle(store: store, secrets: secrets, http: .live, queued: &notices)
        try await AttachmentTransfers(store: store, secrets: secrets, background: false).synchronize()
        for _ in 0..<200 {
            if try store.attachment(staged.id)?.uploaded == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try store.attachment(staged.id)?.uploaded == true)
        let (other, _) = try tempStore(); let otherSecrets = SecretStore.memory()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: otherSecrets)
        _ = try await cycle(store: other, secrets: otherSecrets, http: .live, queued: &notices)
        let downloads = AttachmentTransfers(store: other, secrets: otherSecrets, background: false)
        #expect(try Data(contentsOf: try await downloads.open(staged.id)) == Data("hello".utf8))
        await downloads.release(staged.id)
    }

    @Test func confirmedCountsDiscardTheStrandedWork() throws {
        let (store, secrets) = try connectedToA()
        try store.editText(itemID: "pulled", text: "y", baseRev: 0, nowUs: 2)
        try store.trash(itemID: "pulled", nowUs: 3)
        try store.renameTopic("old", name: "New", nowUs: 4)
        try store.pool.write { db in
            try store.queue(db, "AddAttachment", nowUs: 5, ["item_id": "pulled", "attachment": ["id": "f2"]])
        }
        let kept = try store.capture(text: "kept", to: .inbox, nowUs: 6)
        try store.pool.write { db in
            try store.queue(db, "AddAttachment", nowUs: 6, ["item_id": kept, "attachment": ["id": "f3"]])
        }
        try store.setTrashAfterCopy(true, nowUs: 7)
        try store.pool.write { try $0.execute(sql: "UPDATE device SET pull_cursor = 9") }
        let generation = try store.transferGeneration()

        try store.saveSettings(url: "https://b.example.com", newSecret: "new", secrets: secrets, confirmed: Stranded(changes: 3, files: 1))

        #expect(try outboxTypes(store) == ["CaptureItem", "AddAttachment", "SetTrashAfterCopy"])
        #expect(try store.pool.read { try String.fetchAll($0, sql: "SELECT id FROM items") } == [kept])
        #expect(try count(store, "attachments") == 0)
        #expect(try count(store, "topics") == 0)
        #expect(try cursor(store) == 0)
        #expect(try store.transferGeneration() == generation + 1)
        #expect(try store.serverURL() == "https://b.example.com")
        #expect(try secrets.read() == "new")
    }

    @Test func moreThanConfirmedRefusesAgain() throws {
        let (store, secrets) = try connectedToA()
        try store.pool.write { try $0.execute(sql: "UPDATE attachments SET uploaded = 1") }
        try store.editText(itemID: "pulled", text: "y", baseRev: 0, nowUs: 2)
        try store.trash(itemID: "pulled", nowUs: 3)
        let error = stranded { try store.saveSettings(url: "https://b.example.com", newSecret: "new", secrets: secrets, confirmed: Stranded(changes: 1, files: 0)) }
        #expect(error?.stranded == Stranded(changes: 2, files: 0))
        #expect(try count(store, "outbox") == 2)
        #expect(try count(store, "items") == 1)
        #expect(try secrets.read() == "s3cret")
    }

    @Test func aCaptureIntoAnOldTopicIsKeptButAMoveIntoOneCounts() throws {
        let (store, secrets) = try connectedToA()
        try store.pool.write { try $0.execute(sql: "DELETE FROM attachments") }
        _ = try store.capture(text: "kept", to: .topic("old"), nowUs: 2)
        try store.saveSettings(url: "https://b.example.com", newSecret: "new", secrets: secrets)

        let (moved, movedSecrets) = try connectedToA()
        try moved.pool.write { try $0.execute(sql: "DELETE FROM attachments") }
        let kept = try moved.capture(text: "kept", to: .inbox, nowUs: 2)
        try moved.move(itemID: kept, to: .topic("old"), nowUs: 3)
        let error = stranded { try moved.saveSettings(url: "https://b.example.com", newSecret: "new", secrets: movedSecrets) }
        #expect(error?.stranded == Stranded(changes: 1, files: 0))
    }

    @Test func firstSaveCountsNothing() throws {
        let (store, _) = try tempStore()
        let staged = try store.stageFile(at: AttachmentTests().source())
        _ = try store.capture(text: "early", attachmentIDs: [staged.id], to: .inbox, nowUs: 1)
        _ = try store.createTopic(name: "Mine", nowUs: 2)
        try store.saveSettings(url: "https://a.example.com", newSecret: "s3cret", secrets: .memory())
        #expect(try (count(store, "items"), count(store, "topics"), count(store, "attachments")) == (1, 1, 1))
        #expect(try outboxTypes(store) == ["CaptureItem", "CreateTopic"])
    }

    @Test func secretProblemsAreReportedBeforeAnyCounting() throws {
        let (store, secrets) = try connectedToA()
        #expect(throws: SettingsError(message: "Enter the secret again for a new Server")) {
            try store.saveSettings(url: "https://b.example.com", newSecret: nil, secrets: secrets)
        }
        #expect(throws: SettingsError(message: "The secret can't be blank")) {
            try store.saveSettings(url: "https://b.example.com", newSecret: " ", secrets: secrets)
        }
        let (fresh, _) = try tempStore()
        #expect(throws: SettingsError(message: "Enter the shared secret")) {
            try fresh.saveSettings(url: "https://b.example.com", newSecret: nil, secrets: .memory())
        }
    }

    @Test func aFailedKeychainWriteRestoresThePreviousSecretAndSavesNothing() throws {
        let (store, _) = try connectedToA()
        let box = Mutex<String?>("s3cret")
        // Like the real Keychain write, it deletes the old secret before the add fails.
        let secrets = SecretStore(
            read: { box.withLock { $0 } },
            write: { secret in
                box.withLock { $0 = secret == "s3cret" ? secret : nil }
                if secret != "s3cret" { throw KeychainError(status: errSecInteractionNotAllowed) }
            })
        try store.pool.write { try $0.execute(sql: "UPDATE attachments SET uploaded = 1") }
        #expect(throws: SettingsError.self) { try store.saveSettings(url: "https://b.example.com", newSecret: "new", secrets: secrets) }
        #expect(try secrets.read() == "s3cret")
        #expect(try store.serverURL() == "https://a.example.com")
        #expect(try count(store, "items") == 1)
    }

    @MainActor @Test func aWrongNewSecretForTheSameURLIsRejectedAndTheOldOneKept() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore()
        let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let model = SettingsModel(store: store, secrets: secrets, check: .live, onSaved: {})
        model.secret = "wrong"
        #expect(!(await model.save()))
        #expect(model.error == "The Server rejected this secret.")
        #expect(try secrets.read() == server.secret)
    }

    @Test func strandedMessageWording() {
        let tail = "reached the current Server yet. Switching discards this work for good."
        for (changes, files, head) in [
            (2, 1, "2 changes and 1 file haven't"), (1, 0, "1 change hasn't"), (0, 3, "3 files haven't"),
            (1, 1, "1 change and 1 file haven't"), (0, 1, "1 file hasn't"), (2, 0, "2 changes haven't"),
        ] {
            #expect(Stranded(changes: changes, files: files).message == "\(head) \(tail)")
        }
    }
}
