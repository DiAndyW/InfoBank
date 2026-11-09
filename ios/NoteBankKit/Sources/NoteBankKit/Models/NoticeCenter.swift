import Foundation
import Observation

public struct Notice: Equatable, Identifiable {
    public let id = UUID()
    public enum Action: Equatable { case show, undoTrash, undoClear(DraftPlace), undoMove(Destination), undoBatchTrash([String]) }

    public var actionTitle: String? { guard let action else { return nil }; return action == .show ? "Show" : "Undo" }

    public let message: String
    public let itemID: String
    public let action: Action?
}

@MainActor @Observable
public final class NoticeCenter {
    public private(set) var current: Notice?

    public init() {}

    public func post(_ notices: [SyncNotice]) {
        guard let last = notices.last else { return }
        let more = notices.count > 1 ? " And \(notices.count - 1) more." : ""
        current = Notice(message: last.message + more, itemID: last.itemID, action: [.topic, .topicRenamed].contains(last.kind) ? nil : .show)
    }

    public func postTrashed(itemID: String, copied: Bool = true) {
        current = Notice(message: copied ? "Copied · moved to Trash" : "Item moved to Trash", itemID: itemID, action: .undoTrash)
    }

    public func postMoved(itemID: String, from destination: Destination) {
        current = Notice(message: "Item moved", itemID: itemID, action: .undoMove(destination))
    }

    public func postTrashed(itemIDs: [String], copied: Bool) {
        guard let first = itemIDs.first else { return }
        let count = "\(itemIDs.count) \(itemIDs.count == 1 ? "Item" : "Items")"
        current = Notice(message: count + (copied ? " copied · moved to Trash" : " moved to Trash"), itemID: first, action: .undoBatchTrash(itemIDs))
    }

    public func postBatchCompleted(count: Int, copied: Bool) {
        current = Notice(message: "\(count) \(count == 1 ? "Item" : "Items") \(copied ? "copied" : "restored")", itemID: "", action: nil)
    }

    public func postCopiedText() {
        current = Notice(message: "Copied text", itemID: "", action: nil)
    }

    public func postRestored(itemID: String) {
        current = Notice(message: "Item restored", itemID: itemID, action: .show)
    }

    public func postCleared(_ place: DraftPlace) {
        current = Notice(message: "Cleared", itemID: "", action: .undoClear(place))
    }

    public func dismiss() { current = nil }
}
