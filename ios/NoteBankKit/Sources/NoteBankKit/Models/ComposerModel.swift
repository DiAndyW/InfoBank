import Foundation
import Observation
import UniformTypeIdentifiers

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
