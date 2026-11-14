import Foundation
import Testing
@testable import NoteBankKit

struct TopicBrowseTests {
    private let topics = (0..<12).map { TopicPlace(id: "\($0)", name: String(format: "Topic %02d", $0), count: $0) }

    @Test func browsingKeepsInputOrder() {
        #expect(TopicPlace.browsing(topics, expanded: false).map(\.count) == Array(0..<10))
        #expect(TopicPlace.browsing(topics.reversed(), expanded: true).map(\.id) == topics.reversed().map(\.id))
    }

    @Test func browsingRetainsAnEditedRow() {
        #expect(TopicPlace.browsing(topics.reversed(), expanded: false).map(\.id) == Array(topics.reversed().prefix(10)).map(\.id))
        #expect(TopicPlace.browsing(topics, expanded: false, retaining: "11").map(\.id) == (Array(0..<10) + [11]).map { "\($0)" })
        #expect(TopicPlace.browsing(topics, expanded: true).count == 12)
    }

    @Test func matchingKeepsInputOrder() {
        let tied = [TopicPlace(id: "z", name: "Zebra", count: 0), TopicPlace(id: "a", name: "apple", count: 0)]
        #expect(TopicPlace.browsing(tied, expanded: false).map(\.id) == ["z", "a"])
        #expect(TopicPlace.matching(tied, text: "a").map(\.id) == ["z", "a"])
        #expect(TopicPlace.matching(tied, text: " APP ").map(\.id) == ["a"])
        #expect(TopicPlace.matching(tied, text: "  ").isEmpty)
        #expect(TopicPlace.matching(tied, text: "missing").isEmpty)
    }
}
