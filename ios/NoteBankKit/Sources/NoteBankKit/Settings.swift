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

public struct SettingsError: Error, Equatable, LocalizedError {
    public let message: String

    public var errorDescription: String? { message }
}

extension Store {
    public func serverURL() throws -> String? {
        try pool.read { try String.fetchOne($0, sql: "SELECT server_url FROM device") }
    }

    public func settings(secrets: SecretStore) throws(SettingsError) -> SettingsState {
        let url: String?
        do { url = try serverURL() } catch { throw SettingsError(message: error.localizedDescription) }
        do { return SettingsState(serverURL: url, hasSecret: try secrets.read() != nil) } catch {
            throw SettingsError(message: "Couldn't read the keychain: \(error.localizedDescription)")
        }
    }

    public func saveSettings(url: String, newSecret: String?, secrets: SecretStore) throws(SettingsError) {
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
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
        let serverURL = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized

        // The secret goes first so a keychain failure leaves the URL and mirror untouched.
        if let newSecret {
            let secret = newSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { throw SettingsError(message: "The secret can't be blank") }
            do { try secrets.write(secret) } catch {
                throw SettingsError(message: "Couldn't save to the keychain: \(error.localizedDescription)")
            }
        } else {
            let current = try settings(secrets: secrets)
            guard current.hasSecret else { throw SettingsError(message: "Enter the shared secret") }
            // A mistyped URL must not receive the secret.
            guard current.serverURL == serverURL else { throw SettingsError(message: "Enter the secret again for a new Server") }
        }

        do {
            try pool.write { db in
                let isNewServer = try Bool.fetchOne(db, sql: "SELECT server_url IS NOT ? FROM device", arguments: [serverURL])!
                if isNewServer {
                    // A cursor and mirror only mean something to the Server they came from; pending Captures go to the new one.
                    try db.execute(sql: """
                        DELETE FROM items WHERE id NOT IN
                            (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem');
                        DELETE FROM topics;
                        UPDATE device SET pull_cursor = 0;
                        """)
                }
                try db.execute(sql: "UPDATE device SET server_url = ?", arguments: [serverURL])
            }
        } catch { throw SettingsError(message: error.localizedDescription) }
    }
}
