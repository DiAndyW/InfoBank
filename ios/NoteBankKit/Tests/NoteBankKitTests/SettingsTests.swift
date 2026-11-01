import Foundation
import GRDB
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
}
