public enum LinkPart: Equatable, Sendable {
    case text(String)
    case link(String)
}

public func linkify(_ text: String) -> [LinkPart] {
    let pattern = /https?:\/\/[^\s<>"]+/.matchingSemantics(.unicodeScalar)
    let trailing = Set(".,;:!?)]}'\"".unicodeScalars)
    let scalars = text.unicodeScalars
    var parts: [LinkPart] = []
    var end = scalars.startIndex
    for match in text.matches(of: pattern) {
        var url = scalars[match.range]
        while let last = url.last, trailing.contains(last),
              !(last == ")" && url.count(where: { $0 == "(" }) >= url.count(where: { $0 == ")" }))
        {
            url = url.dropLast()
        }
        if match.range.lowerBound > end { parts.append(.text(String(scalars[end..<match.range.lowerBound]))) }
        parts.append(.link(String(url)))
        end = url.endIndex
    }
    if end < scalars.endIndex { parts.append(.text(String(scalars[end...]))) }
    return parts
}
