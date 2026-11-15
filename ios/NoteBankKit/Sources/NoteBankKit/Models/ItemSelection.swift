import Observation

@MainActor @Observable
public final class ItemSelection {
    public private(set) var ids: Set<String> = []
    public private(set) var isSelecting: Bool = false

    public init() {}

    public func enter() {
        ids.removeAll()
        isSelecting = true
    }

    public func toggle(_ id: String) {
        if !ids.insert(id).inserted { ids.remove(id) }
        isSelecting = !ids.isEmpty
    }

    public func reconcile(_ available: [String]) {
        let hadChosenItems = !ids.isEmpty
        ids.formIntersection(available)
        if hadChosenItems && ids.isEmpty { isSelecting = false }
    }
    public func orderedIDs(in order: [String]) -> [String] { order.filter { ids.contains($0) } }
    public func clear() {
        ids.removeAll()
        isSelecting = false
    }
}
