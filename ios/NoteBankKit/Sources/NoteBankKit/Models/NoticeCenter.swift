import Foundation
import Observation

public struct Notice: Equatable, Identifiable {
    public let id = UUID()
    public enum Action: Equatable { case show, undoTrash, undoMove(Destination) }

    public var actionTitle: String { action == .show ? "Show" : "Undo" }

    public let message: String
    public let itemID: String
    public let action: Action
}

@MainActor @Observable
public final class NoticeCenter {
    public private(set) var current: Notice?

    public init() {}

    public func post(_ notices: [SyncNotice]) {
        guard let last = notices.last else { return }
        let more = notices.count > 1 ? " And \(notices.count - 1) more." : ""
        current = Notice(message: last.message + more, itemID: last.itemID, action: .show)
    }

    public func postTrashed(itemID: String, copied: Bool = true) {
        current = Notice(message: copied ? "Copied · moved to Trash" : "Item moved to Trash", itemID: itemID, action: .undoTrash)
    }

    public func postMoved(itemID: String, from destination: Destination) {
        current = Notice(message: "Item moved", itemID: itemID, action: .undoMove(destination))
    }

    public func dismiss() { current = nil }
}
