import Foundation
import GRDB
import Security

public struct KeychainError: Error, Equatable, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}

public struct SecretStore: Sendable {
    public var read: @Sendable () throws -> String?
    public var write: @Sendable (String) throws -> Void

    public static func keychain(accessGroup: String) -> SecretStore {
        @Sendable func identity() -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "app.notebank",
                kSecAttrAccount as String: "shared-secret",
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
        }
        return SecretStore(
            read: {
                var found: CFTypeRef?
                let query = identity().merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
                let status = SecItemCopyMatching(query as CFDictionary, &found)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess, let data = found as? Data else { throw KeychainError(status: status) }
                return String(decoding: data, as: UTF8.self)
            },
            write: { secret in
                let deleted = SecItemDelete(identity() as CFDictionary)
                guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
                let attributes = identity().merging([
                    kSecValueData as String: Data(secret.utf8),
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]) { $1 }
                let added = SecItemAdd(attributes as CFDictionary, nil)
                guard added == errSecSuccess else { throw KeychainError(status: added) }
            })
    }
}

public struct SettingsState: Equatable, Sendable {
    public let serverURL: String?
    public let hasSecret: Bool
}

public struct Stranded: Equatable, Sendable {
    public var changes: Int
    public var files: Int

    public init(changes: Int = 0, files: Int = 0) {
        self.changes = changes
        self.files = files
    }

    var message: String {
        let plural = { (n: Int, noun: String) in "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if changes > 0 { parts.append(plural(changes, "change")) }
        if files > 0 { parts.append(plural(files, "file")) }
        let verb = changes + files == 1 ? "hasn't" : "haven't"
        return "\(parts.joined(separator: " and ")) \(verb) reached the current Server yet. Switching discards this work for good."
    }
}

public struct SettingsError: Error, Equatable, LocalizedError {
    public let message: String
    public var stranded: Stranded? = nil

    public var errorDescription: String? { message }
}

public struct ServerCheck: Sendable {
    public var run: @Sendable (_ url: String, _ secret: String) async throws(SettingsError) -> Void

    public static let live = ServerCheck { url, secret throws(SettingsError) in
        try await SyncHTTP.live.checkServer(url, secret: secret)
    }
}

extension SyncHTTP {
    func checkServer(_ serverURL: String, secret: String) async throws(SettingsError) {
        guard let url = URL(string: serverURL + "/auth/check") else { throw SettingsError(message: "Couldn't reach the Server.") }
        var request = URLRequest(url: url, timeoutInterval: Self.timeoutSeconds)
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        let response: URLResponse
        do { (_, response) = try await session.data(for: request, delegate: self) } catch {
            throw SettingsError(message: "Couldn't reach the Server.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return
        case 401: throw SettingsError(message: "The Server rejected this secret.")
        case 429:
            guard let seconds = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap({ UInt($0) }) else {
                throw SettingsError(message: "Too many failed attempts. Try again later.")
            }
            let minutes = seconds / 60 + (seconds % 60 == 0 ? 0 : 1)
            throw SettingsError(message: "Too many failed attempts. Try again in \(minutes) minute\(minutes == 1 ? "" : "s").")
        default: throw SettingsError(message: "Couldn't check the Server: it answered \(status).")
        }
    }
}

// Ops naming rows the old Server sent us; the new Server has no such rows to apply them to.
private let doomedWork = """
    (json_extract(op, '$.item_id') IN
        (SELECT id FROM items WHERE id NOT IN
            (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem'))
     OR json_extract(op, '$.topic_id') IN
        (SELECT id FROM topics WHERE id NOT IN
            (SELECT json_extract(op, '$.topic_id') FROM outbox WHERE json_extract(op, '$.type') = 'CreateTopic')))
    """

extension Store {
    public func serverURL() throws -> String? {
        try pool.read { try String.fetchOne($0, sql: "SELECT server_url FROM device") }
    }

    public func settings(secrets: SecretStore) throws(SettingsError) -> SettingsState {
        let url: String?
        do { url = try serverURL() } catch { throw SettingsError(message: errorMessage(error)) }
        do { return SettingsState(serverURL: url, hasSecret: try secrets.read() != nil) } catch {
            throw SettingsError(message: "Couldn't read the keychain: \(errorMessage(error))")
        }
    }

    public static func normalizedServerURL(_ input: String) throws(SettingsError) -> String {
        guard var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty
        else { throw SettingsError(message: "Enter the Server URL, starting with https://") }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw SettingsError(message: "The Server URL must start with https://")
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw SettingsError(message: "The Server URL can't include a user name, query or fragment")
        }
        components.scheme = scheme
        components.host = host
        guard let normalized = components.string else { throw SettingsError(message: "Enter the Server URL, starting with https://") }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    public func saveSettings(url: String, newSecret: String?, secrets: SecretStore, confirmed: Stranded = Stranded()) throws(SettingsError) {
        let serverURL = try Self.normalizedServerURL(url)

        var secret: String?
        if let newSecret {
            let trimmed = newSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SettingsError(message: "The secret can't be blank") }
            secret = trimmed
        } else {
            let current = try settings(secrets: secrets)
            guard current.hasSecret else { throw SettingsError(message: "Enter the shared secret") }
            // A mistyped URL must not receive the secret.
            guard current.serverURL == serverURL else { throw SettingsError(message: "Enter the secret again for a new Server") }
        }

        var previousSecret: String?
        var wroteSecret = false
        do {
            try pool.write { db in
                let isNewServer = try Bool.fetchOne(db, sql: "SELECT server_url IS NOT ? FROM device", arguments: [serverURL])!
                if isNewServer {
                    let changes = try Int.fetchOne(db, sql: """
                        SELECT count(*) FROM outbox
                        WHERE json_extract(op, '$.type') NOT IN ('CaptureItem', 'CreateTopic', 'AddAttachment') AND \(doomedWork)
                        """)!
                    let files = try Int.fetchOne(db, sql: """
                        SELECT count(*) FROM attachments WHERE uploaded = 0 AND item_id NOT IN
                            (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem')
                        """)!
                    let found = Stranded(changes: changes, files: files)
                    if found.changes > confirmed.changes || found.files > confirmed.files {
                        throw SettingsError(message: found.message, stranded: found)
                    }
                    // A cursor and mirror only mean something to the Server they came from; unsynced Captures and Topics go to the new one.
                    try db.execute(sql: """
                        DELETE FROM outbox WHERE json_extract(op, '$.type') NOT IN ('CaptureItem', 'CreateTopic') AND \(doomedWork);
                        DELETE FROM items WHERE id NOT IN
                            (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem');
                        DELETE FROM topics WHERE id NOT IN
                            (SELECT json_extract(op, '$.topic_id') FROM outbox WHERE json_extract(op, '$.type') = 'CreateTopic');
                        DELETE FROM attachment_uploads;
                        UPDATE device SET transfer_generation = transfer_generation + 1;
                        UPDATE device SET pull_cursor = 0;
                        """)
                }
                try db.execute(sql: "UPDATE device SET server_url = ?", arguments: [serverURL])

                // The keychain goes last so only a failed commit needs undoing.
                if let secret {
                    do {
                        previousSecret = try secrets.read()
                        wroteSecret = true
                        try secrets.write(secret)
                    } catch {
                        throw SettingsError(message: "Couldn't save to the keychain: \(errorMessage(error))")
                    }
                }
            }
        } catch {
            if wroteSecret, let previousSecret { try? secrets.write(previousSecret) }
            throw error as? SettingsError ?? SettingsError(message: errorMessage(error))
        }
    }
}
