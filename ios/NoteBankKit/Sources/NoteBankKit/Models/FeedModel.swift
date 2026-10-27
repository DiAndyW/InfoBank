import GRDB
import Observation

extension Store {
    func observeChanges(onChange: @escaping @MainActor @Sendable () -> Void, onError: @escaping @MainActor @Sendable (Error) -> Void)
        -> AnyDatabaseCancellable
    {
        DatabaseRegionObservation(tracking: Table("items"), Table("outbox"), Table("topics"), Table("attachments"))
            .start(
                in: pool,
                onError: { error in Task { @MainActor in onError(error) } },
                onChange: { _ in Task { @MainActor in onChange() } })
    }
}

@MainActor @Observable
public final class FeedModel {
    private static let pageSize = 100

    public private(set) var items: [FeedItem] = []
    public private(set) var hasOlder = false
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
            onError: { [weak self] in self?.loadError = $0.localizedDescription })
    }

    public func loadOlder() {
        do {
            let page = try store.items(in: place, before: items.first?.cursor, limit: Self.pageSize)
            items = page.reversed() + items
            hasOlder = page.count == Self.pageSize
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func reload() {
        guard let oldest = items.first?.cursor else { return loadOlder() }
        do {
            items = try store.items(in: place, from: oldest).reversed()
            hasOlder = try !store.items(in: place, before: oldest, limit: 1).isEmpty
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    public func discard(_ id: String) {
        do {
            try store.discard(itemID: id)
            reload()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
