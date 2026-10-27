import Foundation
import GRDB
import Observation

@MainActor @Observable
public final class SettingsModel {
    public private(set) var trashAfterCopy = false
    public private(set) var trashError: String?
    @ObservationIgnored private var copyObservation: AnyDatabaseCancellable?

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
        refreshTrashAfterCopy()
        copyObservation = DatabaseRegionObservation(tracking: Table("settings"), Table("outbox")).start(
            in: store.pool,
            onError: { [weak self] error in Task { @MainActor in self?.trashError = error.localizedDescription } },
            onChange: { [weak self] _ in Task { @MainActor in self?.refreshTrashAfterCopy() } })
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

    @discardableResult
    public func setTrashAfterCopy(_ on: Bool) -> Bool {
        do {
            try store.setTrashAfterCopy(on, nowUs: Time.nowUs())
            trashAfterCopy = on
            trashError = nil
            return true
        } catch {
            trashError = error.localizedDescription
            return false
        }
    }

    private func refreshTrashAfterCopy() {
        do {
            trashAfterCopy = try store.trashAfterCopy() ?? false
            trashError = nil
        } catch { trashError = error.localizedDescription }
    }

    private func load() {
        guard let saved = try? store.serverURL() else { return }
        url = saved
    }
}
