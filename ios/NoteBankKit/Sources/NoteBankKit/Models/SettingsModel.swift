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
    public private(set) var stranded: SettingsError?

    private let store: Store
    private let secrets: SecretStore
    private let check: ServerCheck
    private let onSaved: @MainActor () -> Void

    public var canSave: Bool {
        !saving && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsSetup || !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public init(store: Store, secrets: SecretStore, check: ServerCheck, onSaved: @escaping @MainActor () -> Void) {
        self.store = store
        self.secrets = secrets
        self.check = check
        self.onSaved = onSaved
        load()
        refreshTrashAfterCopy()
        copyObservation = DatabaseRegionObservation(tracking: Table("settings"), Table("outbox")).start(
            in: store.pool,
            onError: { [weak self] error in Task { @MainActor in self?.trashError = errorMessage(error) } },
            onChange: { [weak self] _ in Task { @MainActor in self?.refreshTrashAfterCopy() } })
        var keychainReadable = true
        do { hasSecret = try store.settings(secrets: secrets).hasSecret } catch {
            self.error = error.message
            keychainReadable = false
        }
        needsSetup = url.isEmpty || (keychainReadable && !hasSecret)
    }

    public func save(confirmed: Stranded = Stranded()) async -> Bool {
        guard canSave else { return false }
        saving = true
        defer { saving = false }
        stranded = nil
        error = nil
        let (store, secrets, check, url) = (store, secrets, check, url)
        let newSecret = secret.isEmpty ? nil : secret
        do {
            let serverURL = try Store.normalizedServerURL(url)
            if let typed = newSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
                try await check.run(serverURL, typed)
            }
            try await Task.detached { try store.saveSettings(url: url, newSecret: newSecret, secrets: secrets, confirmed: confirmed) }.value
        } catch let refusal as SettingsError where refusal.stranded != nil {
            stranded = refusal
            return false
        } catch {
            self.error = errorMessage(error)
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

    public func cancelDiscard() { stranded = nil }

    @discardableResult
    public func setTrashAfterCopy(_ on: Bool) -> Bool {
        do {
            try store.setTrashAfterCopy(on, nowUs: Time.nowUs())
            trashAfterCopy = on
            trashError = nil
            return true
        } catch {
            trashError = errorMessage(error)
            return false
        }
    }

    private func refreshTrashAfterCopy() {
        do {
            trashAfterCopy = try store.trashAfterCopy() ?? false
            trashError = nil
        } catch { trashError = errorMessage(error) }
    }

    private func load() {
        guard let saved = try? store.serverURL() else { return }
        url = saved
    }
}
