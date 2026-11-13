import Foundation
import GRDB
import Observation

@MainActor @Observable
public final class TopicDeletionModel {
    private static let pageSize = 50
    public var text = "" {
        didSet {
            pending?.cancel()
            guard !text.allSatisfy(\.isWhitespace) else { return run() }
            pending = Task { [weak self, debounce] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                self?.run()
            }
        }
    }
    public var kept: Set<String> = []
    public private(set) var total = 0
    public private(set) var items: [FeedItem] = []
    public private(set) var hasMore = false
    public private(set) var error: String?
    private let store: Store
    private let topicID: String
    private let debounce: Duration
    private var loadedText = ""
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?

    public init(store: Store, topicID: String, debounce: Duration = .milliseconds(150)) {
        self.store = store
        self.topicID = topicID
        self.debounce = debounce
        run()
        observation = store.observeChanges(
            onChange: { [weak self] in
                guard let self else { return }
                self.run(limit: max(Self.pageSize, self.items.count))
            },
            onError: { [weak self] in self?.error = errorMessage($0) })
    }

    public func loadMore() {
        guard hasMore, loadedText == text else { return }
        do {
            let page = try page(before: items.last?.cursor, limit: Self.pageSize)
            items += page
            hasMore = page.count == Self.pageSize
            error = nil
        } catch { self.error = errorMessage(error) }
    }

    public func confirmationMessage() throws -> String {
        try refreshCounts()
        let trash = total - kept.count
        if kept.isEmpty { return "All \(total) \(total == 1 ? "Item goes" : "Items go") to Trash." }
        return "\(kept.count) \(kept.count == 1 ? "Item moves" : "Items move") to the Inbox. \(trash) \(trash == 1 ? "goes" : "go") to Trash."
    }

    private func refreshCounts() throws {
        let ids = try store.pool.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM items WHERE topic_id = ? AND deleted_at IS NULL", arguments: [topicID])
        }
        total = ids.count
        kept.formIntersection(ids)
    }

    private func page(before cursor: FeedCursor?, limit: Int) throws -> [FeedItem] {
        if text.allSatisfy(\.isWhitespace) {
            return try store.items(in: .topic(topicID), before: cursor, limit: limit)
        }
        return try store.search(SearchQuery(text: text, place: .topic(topicID)), before: cursor, limit: limit).map(\.item)
    }

    private func run(limit: Int = pageSize) {
        do {
            try refreshCounts()
            items = try page(before: nil, limit: limit)
            loadedText = text
            hasMore = items.count == limit
            error = nil
        } catch {
            items = []
            hasMore = false
            self.error = errorMessage(error)
        }
    }
}
