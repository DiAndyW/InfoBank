import Foundation
import Observation

@MainActor @Observable
public final class SettingsModel {
    public var url = ""
    public var secret = ""
    public private(set) var hasSecret = false
    public private(set) var needsSetup = true
    public private(set) var saving = false
    public private(set) var error: String?

    private let store: Store
    private let secrets: SecretStore
    private let onSaved: @MainActor () -> Void

    public var canSave: Bool {
        !saving && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsSetup || !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public init(store: Store, secrets: SecretStore, onSaved: @escaping @MainActor () -> Void) {
        self.store = store
        self.secrets = secrets
        self.onSaved = onSaved
        load()
        var keychainReadable = true
        do { hasSecret = try store.settings(secrets: secrets).hasSecret } catch {
            self.error = error.message
            keychainReadable = false
        }
        needsSetup = url.isEmpty || (keychainReadable && !hasSecret)
    }

    public func save() async -> Bool {
        guard canSave else { return false }
        saving = true
        defer { saving = false }
        let (store, secrets, url) = (store, secrets, url)
        let newSecret = secret.isEmpty ? nil : secret
        do {
            try await Task.detached { try store.saveSettings(url: url, newSecret: newSecret, secrets: secrets) }.value
        } catch {
            self.error = error.localizedDescription
            return false
        }
        load()
        hasSecret = true
        needsSetup = false
        secret = ""
        error = nil
        onSaved()
        return true
    }

    private func load() {
        guard let saved = try? store.serverURL() else { return }
        url = saved
    }
}
