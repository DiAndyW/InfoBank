import Foundation

public struct TrashGroup: Identifiable {
    public let daysRemaining: Int?
    public let items: [FeedItem]
    public var id: Int { daysRemaining ?? -1 }
    public var title: String {
        guard let daysRemaining else { return "Waiting for sync" }
        return daysRemaining == 1 ? "1 day remaining" : "\(daysRemaining) days remaining"
    }

    public static func group(_ items: [FeedItem], nowUs: Int64) -> [TrashGroup] {
        let groups = Dictionary(grouping: items) { item -> Int? in
            item.purgeAtUs.map { max(0, Int(ceil(Double($0 - nowUs) / 86_400_000_000))) }
        }
        return groups.keys.sorted { ($0 ?? Int.max) < ($1 ?? Int.max) }.map {
            TrashGroup(daysRemaining: $0, items: groups[$0]!.sorted { ($0.captureTimeUs, $0.id) > ($1.captureTimeUs, $1.id) })
        }
    }
}
