import GRDB
import Observation

@MainActor @Observable
public final class PlacesModel {
    public private(set) var places = Places(allCount: 0, inboxCount: 0, topics: [])

    private let store: Store
    @ObservationIgnored private var observation: AnyDatabaseCancellable?

    public init(store: Store) {
        self.store = store
        refresh()
        observation = store.observeChanges(onChange: { [weak self] in self?.refresh() }, onError: { _ in })
    }

    public func refresh() {
        if let places = try? store.places() { self.places = places }
    }
}
