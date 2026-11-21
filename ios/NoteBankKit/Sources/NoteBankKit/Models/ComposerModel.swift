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
    @ObservationIgnored private var nextImport = 0
    @ObservationIgnored private var nextPublication = 0
    @ObservationIgnored private var completedImports: [Int: [StagedAttachment]] = [:]
    @ObservationIgnored private var batches: [(slot: Int, generation: Int, files: [StagedAttachment])] = []
    private var pendingSlots: Set<Int> = []
    public var pendingImportCount: Int { pendingSlots.count }
    public var pendingImportLabel: String { pendingImportCount == 1 ? "1 import pending" : "\(pendingImportCount) imports pending" }
    private var imports = 0
    public var isImporting: Bool { imports > 0 }
    private var failure: String? {
        didSet { draftSaveFailed = false }
    }
    private var attachFailures: [String] = []
    public var error: String? {
        let messages = ([failure] + attachFailures).compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    private var draftSaveFailed = false
    private var draftSaveFailures = 0
    public var placeholder: String
    public var destination: Destination

    private let draft: DraftPlace?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    private var cleared: (text: String, attachments: [StagedAttachment])?
    @ObservationIgnored private var generation = 0
    private var isSending = false
    private let store: Store
    private let clock: any Clock<Duration>
    private let onCaptured: @MainActor () -> Void

    public var canSend: Bool { !isImporting && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    public init(store: Store, destination: Destination, placeholder: String, draft: DraftPlace? = nil, initial: Draft? = nil, clock: any Clock<Duration> = ContinuousClock(), onCaptured: @escaping @MainActor () -> Void) {
        self.store = store
        self.clock = clock
        self.onCaptured = onCaptured
        self.destination = destination
        self.placeholder = placeholder
        self.draft = draft
        self.text = initial?.text ?? ""
        self.attachments = initial?.attachments ?? []
        self.homeTopicID = initial?.homeTopicID
    }

    private func scheduleDraftSave() {
        pendingSave?.cancel()
        guard draft != nil else { return }
        let alarm = clock.alarm(after: .milliseconds(300))
        pendingSave = Task { [weak self] in
            do { try await alarm() }
            catch { return }
            self?.flushDraft()
        }
    }

    public func flushDraft() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let draft else { return }
        do {
            try store.saveDraft(draft, text: text, homeTopicID: homeTopicID, attachmentIDs: attachments.map(\.id))
            draftSaveFailures = 0
            if draftSaveFailed { failure = nil }
        } catch {
            _ = errorMessage(error)
            draftSaveFailures += 1
            if (draftSaveFailures >= 3 || !attachments.isEmpty) && (failure == nil || draftSaveFailed) {
                failure = failureMessage("Draft failed to save.", error)
                draftSaveFailed = true
            }
        }
    }

    public var canClear: Bool { !isSending && (!text.isEmpty || !attachments.isEmpty || pendingImportCount > 0) }

    @discardableResult
    public func clear() -> Bool {
        guard canClear else { return false }
        do { if let draft { try store.saveDraft(draft, text: "", homeTopicID: homeTopicID, attachmentIDs: []) } }
        catch { failure = failureMessage("Draft failed to save.", error); return false }
        generation += 1
        for files in completedImports.values { for file in files { try? store.discardStaged(file.id) } }
        completedImports.removeAll()
        pendingSlots.removeAll()
        nextPublication = nextImport
        attachFailures = []
        cleared = (text, attachments)
        text = ""
        attachments = []
        flushDraft()
        return true
    }

    public func undoClear() {
        guard let snapshot = cleared else { return }
        do { if let draft { try store.saveDraft(draft, text: snapshot.text, homeTopicID: homeTopicID, attachmentIDs: snapshot.attachments.map(\.id)) } }
        catch { failure = failureMessage("Draft failed to save.", error); return }
        cleared = nil
        text = snapshot.text
        attachments = snapshot.attachments
        flushDraft()
    }

    public func dropMissingTopic(open: [TopicPlace]) {
        if case .topic(let id) = destination, !open.contains(where: { $0.id == id }) { destination = .inbox }
    }

    private func reserveImport() -> Int {
        defer { nextImport += 1 }
        attachFailures = []
        imports += 1
        pendingSlots.insert(nextImport)
        return nextImport
    }

    private func completeImport(_ slot: Int, files: [StagedAttachment]) {
        defer { imports -= 1 }
        guard slot >= nextPublication else {
            for file in files { try? store.discardStaged(file.id) }
            return
        }
        completedImports[slot] = files
        while let files = completedImports.removeValue(forKey: nextPublication) {
            if !files.isEmpty { addAttachments(files) }
            pendingSlots.remove(nextPublication)
            nextPublication += 1
        }
    }

    public func beginImport() {
        batches.append((reserveImport(), generation, []))
    }
    public func endImport() {
        guard let batch = batches.popLast() else { return }
        if batch.generation != generation {
            for file in batch.files { try? store.discardStaged(file.id) }
        }
        completeImport(batch.slot, files: batch.generation == generation ? batch.files : [])
    }

    public func addAttachments(_ files: [StagedAttachment]) {
        attachments += files
        flushDraft()
    }

    public func removeAttachment(_ id: String) {
        guard let attachment = attachments.first(where: { $0.id == id }) else { return }
        do {
            let remaining = attachments.filter { $0.id != id }
            if let draft {
                try store.removeDraftAttachment(id, from: draft, text: text, homeTopicID: homeTopicID, attachmentIDs: remaining.map(\.id))
            } else {
                try store.discardStaged(id)
            }
            attachments = remaining
        }
        catch { failure = failureMessage("\(attachment.filename) failed to remove.", error) }
    }

    public func importFile(_ url: URL, filename: String? = nil, startsOperation: Bool = true) async {
        let slot = startsOperation ? reserveImport() : nil
        var imported: [StagedAttachment] = []
        let accepted = startsOperation ? generation : (batches.last?.generation ?? generation)
        defer {
            if let slot { completeImport(slot, files: imported) }
            else if !batches.isEmpty { batches[batches.count - 1].files += imported }
        }
        do {
            let file = try await Task.detached { [store] in try store.stageFile(at: url, filename: filename) }.value
            guard accepted == generation else { try store.discardStaged(file.id); return }
            imported = [file]
        } catch { if accepted == generation { attachFailures.append(attachmentFailureMessage(filename ?? url.lastPathComponent, error)) } }
    }

    public func reportImportError(_ message: String) {
        guard batches.last.map({ $0.generation == generation }) ?? true else { return }
        attachFailures.append(message)
    }

    @discardableResult
    public func importPaste(_ provider: NSItemProvider, type: UTType) -> Task<Void, Never> {
        let slot = reserveImport()
        let accepted = generation
        let store = store
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
        let filename = (name as NSString).pathExtension.isEmpty ? name + "." + (type.preferredFilenameExtension ?? "bin") : name
        return Task {
            var imported: [StagedAttachment] = []
            defer { completeImport(slot, files: imported) }
            do {
                let staged: StagedAttachment = try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        guard let url else {
                            continuation.resume(throwing: error ?? AttachmentError(genericFailure))
                            return
                        }
                        // The provider's temporary file is valid only until this callback returns.
                        do { continuation.resume(returning: try store.stageFile(at: url, filename: filename)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                guard accepted == generation else { try store.discardStaged(staged.id); return }
                imported = [staged]
            } catch { if accepted == generation { attachFailures.append(attachmentFailureMessage(filename, error)) } }
        }
    }

    public func stagedFile(_ id: String) throws -> URL {
        guard attachments.contains(where: { $0.id == id }), let url = try store.localFile(id) else {
            throw AttachmentError("This image can't be shown here.")
        }
        return url
    }

    public func send() -> Bool {
        guard !isImporting && !isSending else { return false }
        generation += 1
        isSending = true
        defer { isSending = false }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            _ = try store.capture(text: text, attachmentIDs: attachments.map(\.id), to: destination, draft: draft, nowUs: Time.nowUs())
        } catch {
            failure = failureMessage("Item failed to send.", error)
            flushDraft()
            return false
        }
        cleared = nil
        attachments = []
        text = ""
        pendingSave?.cancel()
        pendingSave = nil
        failure = nil
        attachFailures = []
        onCaptured()
        return true
    }
}
