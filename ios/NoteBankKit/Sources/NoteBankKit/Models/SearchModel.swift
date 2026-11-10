import Foundation
import GRDB
import Observation

public enum SearchDates: Hashable, Sendable {
    case any, pastWeek, pastMonth, pastYear
    case custom(from: Date?, to: Date?)
}

@MainActor @Observable
public final class SearchModel {
    private static let pageSize = 100

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
    public var place: SearchPlace { didSet { run() } }
    public var dates = SearchDates.any {
        didSet {
            presetFromUs = switch dates {
            case .pastWeek: startUs(calendar.date(byAdding: .day, value: -7, to: now()))
            case .pastMonth: startUs(calendar.date(byAdding: .month, value: -1, to: now()))
            case .pastYear: startUs(calendar.date(byAdding: .month, value: -12, to: now()))
            case .any, .custom: nil
            }
            run()
        }
    }
    public var hasFiles = false { didSet { run() } }
    public private(set) var results: [SearchItem] = []
    public private(set) var hasMore = false
    public private(set) var error: String?

    private var lastRun: SearchQuery?
    @ObservationIgnored private var presetFromUs: Int64?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    private let store: Store
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let debounce: Duration

    public var query: SearchQuery? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        var fromUs = presetFromUs
        var toUs: Int64?
        if case .custom(let from, let to) = dates {
            fromUs = from.flatMap { startUs(calendar.startOfDay(for: $0)) }
            toUs = to.flatMap { startUs(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))) }
        }
        return SearchQuery(text: text, place: place, fromUs: fromUs, toUs: toUs, hasFiles: hasFiles)
    }
    public var hasFilters: Bool { place != .all || dates != .any || hasFiles }
    public var isEmptyResult: Bool { query != nil && query == lastRun && error == nil && results.isEmpty }

    public init(store: Store, place: SearchPlace = .all, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }, debounce: Duration = .milliseconds(150)) {
        self.store = store
        self.place = if case .topic(let id) = place, (try? store.topic(id)) == nil { .all } else { place }
        self.calendar = calendar
        self.now = now
        self.debounce = debounce
        observation = store.observeChanges(
            onChange: { [weak self] in self?.databaseChanged() },
            onError: { [weak self] in self?.error = errorMessage($0) })
    }

    public func loadMore() {
        guard hasMore, let query = lastRun else { return }
        do {
            let page = try store.search(query, before: results.last?.item.cursor, limit: Self.pageSize)
            results += page
            hasMore = page.count == Self.pageSize
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    public func clearFilters() {
        place = .all
        dates = .any
        hasFiles = false
    }

    private func startUs(_ date: Date?) -> Int64? { date.map { Int64(($0.timeIntervalSince1970 * 1_000_000).rounded()) } }

    private func databaseChanged() {
        if case .topic(let id) = place, (try? store.topic(id)) == nil {
            place = .all
        } else {
            run(limit: max(Self.pageSize, results.count))
        }
    }

    private func run(limit: Int = pageSize) {
        guard let query else {
            (results, hasMore, error, lastRun) = ([], false, nil, nil)
            return
        }
        lastRun = query
        do {
            results = try store.search(query, before: nil, limit: limit)
            hasMore = results.count == limit
            error = nil
        } catch {
            (results, hasMore) = ([], false)
            self.error = errorMessage(error)
        }
    }
}
