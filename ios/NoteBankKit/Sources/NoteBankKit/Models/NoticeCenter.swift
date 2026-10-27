import Observation

@MainActor @Observable
public final class NoticeCenter {
    public private(set) var current: (message: String, itemID: String)?

    public init() {}

    public func post(_ notices: [SyncNotice]) {
        guard let last = notices.last else { return }
        let more = notices.count > 1 ? " And \(notices.count - 1) more." : ""
        current = (last.message + more, last.itemID)
    }

    public func dismiss() { current = nil }
}
