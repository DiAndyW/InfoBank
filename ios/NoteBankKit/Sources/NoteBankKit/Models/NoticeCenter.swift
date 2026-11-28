import Foundation
import Observation

public struct Notice: Equatable, Identifiable {
    public static let durationSeconds: Double = 4
    public static let maxFilenameCharacters = 40

    public static func filename(_ name: String) -> String {
        name.count > maxFilenameCharacters ? String(name.prefix(maxFilenameCharacters)) + "…" : name
    }

    public let id = UUID()
    public enum Action: Equatable { case download(attachmentID: String), show, undoTrash, undoClear(DraftPlace), undoMove(Destination), undoBatchTrash([String]) }

    public var actionTitle: String? {
        guard let action else { return nil }
        switch action {
        case .download: return "Download"
        case .show: return "Show"
        default: return "Undo"
        }
    }

    public let message: String
    public let itemID: String
    public let action: Action?
}

public struct DownloadRequest: Equatable {
    public let id: UUID
    public let attachmentID: String
}

@MainActor @Observable
public final class NoticeCenter {
    public private(set) var current: Notice?
    public private(set) var download: DownloadRequest?

    public init() {}

    @discardableResult
    public func postUnsupported(_ attachment: FeedAttachment) -> UUID {
        let notice = Notice(message: attachment.unsupportedMessage, itemID: "", action: .download(attachmentID: attachment.id))
        current = notice
        return notice.id
    }

    public func requestDownload(_ attachmentID: String) {
        download = DownloadRequest(id: UUID(), attachmentID: attachmentID)
        dismiss()
    }

    public func post(_ notices: [SyncNotice]) {
        guard let last = notices.last else { return }
        let more = notices.count > 1 ? " And \(notices.count - 1) more." : ""
        current = Notice(message: last.message + more, itemID: last.itemID, action: [.move, .inbox, .failed].contains(last.kind) && !last.itemID.isEmpty ? .show : nil)
    }

    public func postTrashed(itemID: String, copied: Bool = true) {
        current = Notice(message: copied ? "Copied, moved to Trash" : "Item moved to Trash", itemID: itemID, action: .undoTrash)
    }

    public func postMoved(itemID: String, from destination: Destination, store: Store) throws {
        guard let item = try store.items(ids: [itemID]).first else { throw ItemActionError.notFound }
        let name = item.inTunnel ? "the Tunnel" : item.topicName ?? "the Inbox"
        current = Notice(message: "Moved to \(name)", itemID: itemID, action: .undoMove(destination))
    }

    public func postTrashed(itemIDs: [String], copied: Bool) {
        guard let first = itemIDs.first else { return }
        let count = "\(itemIDs.count) \(itemIDs.count == 1 ? "Item" : "Items")"
        current = Notice(message: count + (copied ? " copied, moved to Trash" : " moved to Trash"), itemID: first, action: .undoBatchTrash(itemIDs))
    }

    public func postBatchCompleted(count: Int, copied: Bool) {
        current = Notice(message: "\(count) \(count == 1 ? "Item" : "Items") \(copied ? "copied" : "restored")", itemID: "", action: nil)
    }

    public func postCopiedText() {
        current = Notice(message: "Copied text", itemID: "", action: nil)
    }

    public func postRestored(itemID: String, store: Store) throws {
        guard let item = try store.items(ids: [itemID]).first else { throw ItemActionError.notFound }
        let name = item.inTunnel ? "Tunnel" : item.topicName ?? "Inbox"
        current = Notice(message: "Restored to \(name)", itemID: itemID, action: .show)
    }

    public func postCleared(_ place: DraftPlace) {
        current = Notice(message: "Cleared", itemID: "", action: .undoClear(place))
    }

    public func postTopicDeleted(_ message: String) {
        current = Notice(message: message, itemID: "", action: nil)
    }

    public func dismiss(id: UUID) {
        if current?.id == id { current = nil }
    }

    public func dismiss() { current = nil }
}
