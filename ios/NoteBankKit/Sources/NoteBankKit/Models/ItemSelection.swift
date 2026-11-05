import Observation

@MainActor @Observable
public final class ItemSelection {
    public private(set) var ids: Set<String> = []
    public var isSelecting: Bool { !ids.isEmpty }

    public init() {}

    public func begin(_ id: String) { ids = [id] }

    public func toggle(_ id: String) {
        if !ids.insert(id).inserted { ids.remove(id) }
    }

    public func reconcile(_ available: [String]) { ids.formIntersection(available) }
    public func orderedIDs(in order: [String]) -> [String] { order.filter { ids.contains($0) } }
    public func clear() { ids.removeAll() }
}
