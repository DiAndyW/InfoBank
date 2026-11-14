import Foundation
import GRDB

public enum SearchPlace: Hashable, Sendable {
    case all, inbox, tunnel, topic(String)
}

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    public var place: SearchPlace
    public var fromUs: Int64?
    public var toUs: Int64?
    public var hasFiles: Bool

    public init(text: String, place: SearchPlace = .all, fromUs: Int64? = nil, toUs: Int64? = nil, hasFiles: Bool = false) {
        self.text = text
        self.place = place
        self.fromUs = fromUs
        self.toUs = toUs
        self.hasFiles = hasFiles
    }
}

public struct SearchItem: Identifiable, Hashable, Sendable {
    public static let markStart: Character = "\u{E000}"
    public static let markEnd: Character = "\u{E001}"

    public let item: FeedItem
    public let markedText: String?
    public let markedFilenames: [String]
    public var id: String { item.id }
}

public enum SearchError: Error, Equatable, LocalizedError {
    case blank

    public var errorDescription: String? { "Type something to search" }
}

public func searchMarks(_ marked: String) -> (plain: String, ranges: [Range<String.Index>]) {
    var plain = ""
    var spans: [Range<Int>] = []
    var open = 0
    for scalar in marked.unicodeScalars {
        switch Character(scalar) {
        case SearchItem.markStart: open = plain.utf8.count
        case SearchItem.markEnd: spans.append(open..<plain.utf8.count)
        default: plain.unicodeScalars.append(scalar)
        }
    }
    let index = { plain.utf8.index(plain.utf8.startIndex, offsetBy: $0) }
    return (plain, spans.map { index($0.lowerBound)..<index($0.upperBound) })
}

extension Store {
    public func search(_ query: SearchQuery, before cursor: FeedCursor?, limit: Int) throws -> [SearchItem] {
        let words = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw SearchError.blank }
        // The trigram index can't match under 3 characters, so those words are checked row by row.
        let long = words.filter { $0.unicodeScalars.count >= 3 }
        let short = words.filter { $0.unicodeScalars.count < 3 }

        var place = "all"
        var topicID: String?
        switch query.place {
        case .all: break
        case .inbox: place = "inbox"
        case .tunnel: place = "tunnel"
        case .topic(let id): (place, topicID) = ("topic", id)
        }
        var arguments: [String: (any DatabaseValueConvertible)?] = [
            "place": place, "topic": topicID, "from": query.fromUs, "to": query.toUs, "hasFiles": query.hasFiles,
            "short": String(decoding: try JSONEncoder().encode(short), as: UTF8.self),
            "beforeTime": cursor?.captureTimeUs, "beforeID": cursor?.id, "limit": limit,
        ]
        var matched = ""
        var markedText = "search.text"
        var markedNames = "search.names"
        if !long.isEmpty {
            // Each word is a quoted phrase, so typed FTS5 syntax is matched as text.
            arguments["match"] = long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " ")
            arguments["markStart"] = String(SearchItem.markStart)
            arguments["markEnd"] = String(SearchItem.markEnd)
            matched = "search MATCH :match AND"
            markedText = "highlight(search, 0, :markStart, :markEnd)"
            markedNames = "highlight(search, 1, :markStart, :markEnd)"
        }

        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.feedColumns), \(markedText) AS marked_text, \(markedNames) AS marked_names
                    FROM search JOIN items ON items.rowid = search.rowid LEFT JOIN topics ON topics.id = items.topic_id
                    WHERE \(matched) items.deleted_at IS NULL
                      AND CASE :place WHEN 'all' THEN 1 WHEN 'inbox' THEN items.topic_id IS NULL AND items.in_tunnel = 0
                                      WHEN 'tunnel' THEN items.in_tunnel = 1 ELSE items.topic_id = :topic END
                      AND (:from IS NULL OR items.capture_time >= :from) AND (:to IS NULL OR items.capture_time < :to)
                      AND (NOT :hasFiles OR EXISTS (SELECT 1 FROM attachments WHERE item_id = items.id))
                      AND NOT EXISTS (SELECT 1 FROM json_each(:short) WHERE instr(lower(search.text || char(10) || search.names), lower(value)) = 0)
                      AND (:beforeTime IS NULL OR (items.capture_time, items.id) < (:beforeTime, :beforeID))
                    ORDER BY items.capture_time DESC, items.id DESC
                    LIMIT :limit
                    """,
                arguments: StatementArguments(arguments))
            return try zip(rows, Self.feedItems(db, rows)).map { row, item in
                let names = (row["marked_names"] as String).split(separator: "\n", omittingEmptySubsequences: false)
                return SearchItem(
                    item: item,
                    markedText: item.text == nil ? nil : row["marked_text"],
                    markedFilenames: item.attachments.map { attachment in
                        names.first { searchMarks(String($0)).plain == attachment.filename }.map(String.init) ?? attachment.filename
                    })
            }
        }
    }
}
