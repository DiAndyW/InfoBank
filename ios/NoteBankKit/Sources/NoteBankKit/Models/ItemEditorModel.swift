import Foundation
import Observation

public enum EditOutcome: Equatable { case saved, trashed }

@MainActor @Observable
public final class ItemEditorModel {
    public static let trashTitle = "Move this Item to Trash?"
    public static let moveToTrash = "Move to Trash"
    public static let cancel = "Cancel"
    public static let clearLabel = "Clear"
    public static let discardTitle = "Discard your changes?"
    public static let keepEditing = "Keep Editing"
    public static let discardAction = "Discard"

    public var text: String
    public private(set) var kept: [FeedAttachment]
    public let staging: ComposerModel
    public private(set) var error: String?

    private let store: Store
    private let item: FeedItem
    private let openingText: String

    public init(store: Store, item: FeedItem, text: String) {
        self.store = store
        self.item = item
        self.text = text
        openingText = text
        kept = item.attachments
        staging = ComposerModel(store: store, destination: item.destination, placeholder: "", onCaptured: {})
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && kept.isEmpty && staging.attachments.isEmpty
    }
    public var hasChanges: Bool {
        text != openingText || kept != item.attachments || !staging.attachments.isEmpty || staging.isImporting
    }
    public var canSave: Bool { !staging.isImporting }

    public func remove(_ id: String) {
        kept.removeAll { $0.id == id }
        staging.removeAttachment(id)
    }

    public func save(nowUs: Int64) -> EditOutcome? {
        guard canSave else { return nil }
        do {
            let removed = Set(item.attachments.map(\.id)).subtracting(kept.map(\.id))
            let trashed = try store.editItem(itemID: item.id, text: text, baseRev: item.editBase, adding: staging.attachments.map(\.id), removing: removed, nowUs: nowUs)
            error = nil
            return trashed ? .trashed : .saved
        } catch {
            self.error = failureMessage("Edit failed to save.", error)
            return nil
        }
    }

    public func clear() {
        guard !staging.isImporting else { return }
        text = ""
        kept = []
        discard()
    }

    public func discard() {
        guard !staging.isImporting else { return }
        for attachment in staging.attachments { staging.removeAttachment(attachment.id) }
    }
}

@MainActor @Observable
public final class EditorNavigation {
    public private(set) var editor: ItemEditorModel?
    public var confirmingLeave = false
    @ObservationIgnored private var onEnd: ((@escaping () -> Void) -> Void)?
    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var closing: UUID?
    @ObservationIgnored private var afterClose: [() -> Void] = []

    public init() {}

    public func begin(_ editor: ItemEditorModel, onEnd: @escaping (@escaping () -> Void) -> Void) {
        guard self.editor == nil, closing == nil else { return }
        self.editor = editor
        self.onEnd = onEnd
    }

    public func end(then action: @escaping () -> Void = {}) {
        afterClose.append(action)
        guard closing == nil else { return }
        guard let onEnd else {
            let actions = afterClose
            afterClose = []
            actions.forEach { $0() }
            return
        }
        let identity = UUID()
        closing = identity
        pending = nil
        confirmingLeave = false
        onEnd { [weak self] in
            guard let self, self.closing == identity else { return }
            self.editor = nil
            self.onEnd = nil
            self.closing = nil
            let actions = self.afterClose
            self.afterClose = []
            actions.forEach { $0() }
        }
    }

    public func requestLeave(_ action: @escaping () -> Void) {
        if closing != nil {
            end(then: action)
        } else if editor?.hasChanges == true {
            pending = action
            confirmingLeave = true
        } else {
            editor?.discard()
            end(then: action)
        }
    }

    public func keepEditing() {
        pending = nil
        confirmingLeave = false
    }

    public func discardAndLeave() {
        guard closing == nil, editor?.canSave != false else { return }
        let action = pending
        editor?.discard()
        end { action?() }
    }
}
