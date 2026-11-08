import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
public final class ComposerModel {
    public var text = "" {
        didSet {
            if !text.isEmpty { cleared = nil }
            scheduleDraftSave()
        }
    }
    public var homeTopicID: String? {
        didSet { if draft == .home { scheduleDraftSave() } }
    }
    public private(set) var attachments: [StagedAttachment] = [] {
        didSet { if !attachments.isEmpty { cleared = nil } }
    }
    private var imports = 0
    public var isImporting: Bool { imports > 0 }
    public private(set) var error: String?
    public var placeholder: String
    public var destination: Destination

    private let draft: DraftPlace?
    private var pendingSave: Task<Void, Never>?
    private var cleared: (text: String, attachments: [StagedAttachment])?
    private var isSending = false
    private let store: Store
    private let onCaptured: @MainActor () -> Void

    public var canSend: Bool { !isImporting && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    public init(store: Store, destination: Destination, placeholder: String, draft: DraftPlace? = nil, initial: Draft? = nil, onCaptured: @escaping @MainActor () -> Void) {
        self.store = store
        self.onCaptured = onCaptured
        self.destination = destination
        self.placeholder = placeholder
        self.draft = draft
        self.text = initial?.text ?? ""
        self.homeTopicID = initial?.homeTopicID
    }

    private func scheduleDraftSave() {
        pendingSave?.cancel()
        guard draft != nil else { return }
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            self?.flushDraft()
        }
    }

    public func flushDraft() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let draft else { return }
        do { try store.saveDraft(draft, text: text, homeTopicID: homeTopicID) }
        catch { self.error = error.localizedDescription }
    }

    public var canClear: Bool { !isSending && (!text.isEmpty || !attachments.isEmpty) }

    public func clear() {
        guard canClear else { return }
        cleared = (text, attachments)
        text = ""
        attachments = []
        flushDraft()
    }

    public func undoClear() {
        guard let snapshot = cleared else { return }
        cleared = nil
        text = snapshot.text
        attachments = snapshot.attachments
        flushDraft()
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

    @discardableResult
    public func importPaste(_ provider: NSItemProvider, type: UTType) -> Task<Void, Never> {
        beginImport()
        let store = store
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
        let filename = (name as NSString).pathExtension.isEmpty ? name + "." + (type.preferredFilenameExtension ?? "bin") : name
        return Task {
            defer { endImport() }
            do {
                let staged: StagedAttachment = try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        guard let url else {
                            continuation.resume(throwing: error ?? AttachmentError("Couldn't paste the attachment"))
                            return
                        }
                        // The provider's temporary file is valid only until this callback returns.
                        do { continuation.resume(returning: try store.stageFile(at: url, filename: filename)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                attachments.append(staged)
            } catch { self.error = "Couldn't paste the attachment: " + error.localizedDescription }
        }
    }

    public func send() -> Bool {
        guard !isImporting && !isSending else { return false }
        isSending = true
        defer { isSending = false }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            _ = try store.capture(text: text, attachmentIDs: attachments.map(\.id), to: destination, draft: draft, nowUs: Time.nowUs())
        } catch {
            self.error = error.localizedDescription
            flushDraft()
            return false
        }
        cleared = nil
        attachments = []
        text = ""
        pendingSave?.cancel()
        pendingSave = nil
        error = nil
        onCaptured()
        return true
    }
}
