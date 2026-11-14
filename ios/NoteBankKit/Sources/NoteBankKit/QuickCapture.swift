import Foundation
import GRDB

public struct QuickPlace: Hashable, Sendable {
    public let destination: Destination
    public let name: String
    public let lastUsedUs: Int64?
}

extension Destination {
    public var placeID: String {
        switch self {
        case .inbox: "inbox"
        case .tunnel: "tunnel"
        case .topic(let id): "topic:\(id)"
        }
    }

    public init?(placeID: String) {
        switch placeID {
        case "inbox": self = .inbox
        case "tunnel": self = .tunnel
        case _ where placeID.hasPrefix("topic:") && placeID.count > "topic:".count: self = .topic(String(placeID.dropFirst("topic:".count)))
        default: return nil
        }
    }
}

extension Store {
    public func quickPlaces() throws -> [QuickPlace] {
        try pool.read { db in
            let tunnelUs = try Int64.fetchOne(db, sql: "SELECT max(capture_time) FROM items WHERE in_tunnel = 1 AND deleted_at IS NULL")
            let topics = try Self.rankedTopics(db).map {
                QuickPlace(destination: .topic($0.place.id), name: $0.place.name, lastUsedUs: $0.lastUsedUs)
            }
            return [QuickPlace(destination: .inbox, name: "Inbox", lastUsedUs: nil), QuickPlace(destination: .tunnel, name: "Tunnel", lastUsedUs: tunnelUs)] + topics
        }
    }

    public func quickPlace(_ destination: Destination) throws -> QuickPlace? {
        try quickPlaces().first { $0.destination == destination }
    }

    public func placeName(_ destination: Destination) throws -> String {
        switch destination {
        case .inbox: return "Inbox"
        case .tunnel: return "Tunnel"
        case .topic(let id):
            return try pool.read { try String.fetchOne($0, sql: "SELECT name FROM topics WHERE id = ?", arguments: [id]) } ?? "Removed Topic"
        }
    }
}

public func usedLabel(lastUsedUs: Int64?, nowUs: Int64, calendar: Calendar) -> String? {
    guard let lastUsedUs else { return nil }
    let used = Date(timeIntervalSince1970: Double(lastUsedUs) / 1_000_000)
    let now = Date(timeIntervalSince1970: Double(nowUs) / 1_000_000)
    if calendar.isDate(used, inSameDayAs: now) { return "Used today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(used, inSameDayAs: yesterday) { return "Used yesterday" }
    var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
    if calendar.component(.year, from: used) != calendar.component(.year, from: now) { style = style.year() }
    return "Used " + used.formatted(style)
}
