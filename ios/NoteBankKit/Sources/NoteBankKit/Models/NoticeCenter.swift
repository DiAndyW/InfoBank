import Observation

public struct Notice: Equatable {
    public enum Action { case show, undoTrash }

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

    public func postTrashed(itemID: String) {
        current = Notice(message: "Copied · moved to Trash", itemID: itemID, action: .undoTrash)
    }

    public func dismiss() { current = nil }
}
