import Foundation
import Observation

@MainActor @Observable
public final class ComposerModel {
    public var text = ""
    public private(set) var attachments: [StagedAttachment] = []
    private var imports = 0
    public var isImporting: Bool { imports > 0 }
    public private(set) var error: String?
    public let placeholder: String
    public var destination: Destination

    private let store: Store
    private let onCaptured: @MainActor () -> Void

    public var canSend: Bool { !isImporting && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    public init(store: Store, destination: Destination, placeholder: String, onCaptured: @escaping @MainActor () -> Void) {
        self.store = store
        self.onCaptured = onCaptured
        self.destination = destination
        self.placeholder = placeholder
    }

    public func dropMissingTopic(open: [TopicPlace]) {
        if case .topic(let id) = destination, !open.contains(where: { $0.id == id }) { destination = .inbox }
    }

    public func beginImport() { imports += 1 }
    public func endImport() { imports = max(0, imports - 1) }

    public func addAttachments(_ files: [StagedAttachment]) { attachments += files }

    public func removeAttachment(_ id: String) {
        do { try store.discardStaged(id); attachments.removeAll { $0.id == id } }
        catch { self.error = error.localizedDescription }
    }

    public func importFile(_ url: URL, filename: String? = nil) async {
        beginImport()
        defer { endImport() }
        do {
            let file = try await Task.detached { [store] in try store.stageFile(at: url, filename: filename) }.value
            attachments.append(file)
        } catch { self.error = error.localizedDescription }
    }

    public func reportImportError(_ message: String) { error = message }

    public func send() -> Bool {
        guard !isImporting else { return false }
        do {
            _ = try store.capture(text: text, attachmentIDs: attachments.map(\.id), to: destination, nowUs: Time.nowUs())
        } catch {
            self.error = error.localizedDescription
            return false
        }
        attachments = []
        text = ""
        error = nil
        onCaptured()
        return true
    }
}
