import Foundation

public struct FeedRow: Identifiable {
    public let item: FeedItem
    public let showsTime: Bool
    public var id: String { item.id }
}

public struct FeedDay: Identifiable {
    public let start: Date
    public var rows: [FeedRow]
    public var id: Date { start }

    public static func group(_ items: [FeedItem], calendar: Calendar = .current) -> [FeedDay] {
        var days: [FeedDay] = []
        for item in items {
            let date = item.date
            let start = calendar.startOfDay(for: date)
            if days.last?.start == start, let above = days.last?.rows.last?.item.date {
                days[days.count - 1].rows.append(FeedRow(item: item, showsTime: !calendar.isDate(date, equalTo: above, toGranularity: .minute)))
            } else {
                days.append(FeedDay(start: start, rows: [FeedRow(item: item, showsTime: true)]))
            }
        }
        return days
    }
}

extension FeedItem {
    public var date: Date { Date(timeIntervalSince1970: Double(captureTimeUs) / 1_000_000) }
}
