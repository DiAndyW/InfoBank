import GRDB
import Observation

extension Store {
    func observeChanges(onChange: @escaping @MainActor @Sendable () -> Void, onError: @escaping @MainActor @Sendable (Error) -> Void)
        -> AnyDatabaseCancellable
    {
        DatabaseRegionObservation(tracking: Table("settings"), Table("items"), Table("outbox"), Table("topics"), Table("attachments"), Table("conflicts"), Table("attachment_uploads"))
            .start(
                in: pool,
                onError: { error in Task { @MainActor in onError(error) } },
                onChange: { _ in Task { @MainActor in onChange() } })
    }
}

public enum CopyOutcome: Equatable { case copied, trashed, ask }

@MainActor @Observable
public final class FeedModel {
    private static let pageSize = 100

    public private(set) var trashAfterCopy: Bool? = false
    public private(set) var items: [FeedItem] = []
    public private(set) var hasOlder = false
    public private(set) var topicUnavailable = false
    public private(set) var topicCount = 0
    public private(set) var topicName: String?
    public private(set) var loadError: String?

    private let store: Store
    private let place: Place
    @ObservationIgnored private var observation: AnyDatabaseCancellable?

    public init(store: Store, place: Place) {
        self.store = store
        self.place = place
        reload()
        observation = store.observeChanges(
            onChange: { [weak self] in self?.reload() },
            onError: { [weak self] in self?.trashAfterCopy = false; self?.loadError = errorMessage($0) })
    }

    public func loadOlder() {
        do {
            let page = try store.items(in: place, before: (place == .trash ? items.last : items.first)?.cursor, limit: Self.pageSize)
            items = place == .trash ? items + page : page.reversed() + items
            hasOlder = page.count == Self.pageSize
            loadError = nil
        } catch {
            loadError = errorMessage(error)
        }
    }

    public func reveal(_ itemID: String) -> Bool {
        if place != .trash, !items.contains(where: { $0.id == itemID }) {
            do {
                if let cursor = try store.cursor(ofItem: itemID, in: place),
                    items.first.map({ (cursor.captureTimeUs, cursor.id) < ($0.captureTimeUs, $0.id) }) ?? true
                {
                    // A page above the target keeps "load older" out of view when the Feed centres it.
                    let older = try store.items(in: place, before: cursor, limit: Self.pageSize)
                    items = try older.reversed() + store.items(in: place, from: cursor).reversed()
                    hasOlder = older.count == Self.pageSize
                }
                loadError = nil
            } catch {
                loadError = errorMessage(error)
            }
        }
        return items.contains { $0.id == itemID }
    }

    public func reload() {
        do { trashAfterCopy = try store.trashAfterCopy() } catch { trashAfterCopy = false }
        if case .topic(let id) = place {
            let topic = try? store.topic(id)
            topicUnavailable = topic?.archived != false
            topicName = topic?.name
            topicCount = topic?.count ?? 0
        }
        guard let oldest = (place == .trash ? items.last : items.first)?.cursor else { return loadOlder() }
        do {
            let loaded = try store.items(in: place, from: oldest)
            items = place == .trash ? loaded : loaded.reversed()
            hasOlder = try !store.items(in: place, before: oldest, limit: 1).isEmpty
            loadError = nil
        } catch {
            loadError = errorMessage(error)
        }
    }

    public func discard(_ id: String) {
        do {
            try store.discard(itemID: id)
            reload()
        } catch {
            loadError = errorMessage(error)
        }
    }

    public func copied(_ item: FeedItem) -> CopyOutcome {
        do { return copied(item, preference: try store.trashAfterCopy()) }
        catch {
            loadError = errorMessage(error)
            return .copied
        }
    }

    public func copied(_ item: FeedItem, preference: Bool?) -> CopyOutcome {
        guard item.syncError == nil else { return .copied }
        do {
            switch preference {
            case true?:
                try store.trash(itemID: item.id, nowUs: Time.nowUs())
                reload()
                return .trashed
            case false?: return .copied
            case nil: return .ask
            }
        } catch {
            loadError = errorMessage(error)
            return .copied
        }
    }

    @discardableResult
    public func answerTrashAfterCopy(_ on: Bool, item: FeedItem) -> Bool {
        do {
            let nowUs = Time.nowUs()
            try store.setTrashAfterCopy(on, nowUs: nowUs)
            if on { try store.trash(itemID: item.id, nowUs: nowUs) }
            reload()
            return true
        } catch {
            loadError = errorMessage(error)
            return false
        }
    }

    public func undoTrash(itemID: String) {
        do {
            try store.restore(itemID: itemID, nowUs: Time.nowUs())
            reload()
        } catch {
            loadError = errorMessage(error)
        }
    }
}
