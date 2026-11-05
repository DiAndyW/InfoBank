import Foundation
import Testing
@testable import NoteBankKit

struct TopicBrowseTests {
    private let topics = (0..<12).map { TopicPlace(id: "\($0)", name: String(format: "Topic %02d", $0), count: $0) }

    @Test func ranksOpenAndExpandsAlphabetically() {
        #expect(TopicPlace.browsing(topics, archived: false, expanded: false).map(\.count) == Array((2...11).reversed()))
        #expect(TopicPlace.browsing(topics, archived: false, expanded: true).map(\.id) == topics.map(\.id))
    }

    @Test func archivedIsAlphabeticalAndCanRetainAnEditedRow() {
        #expect(TopicPlace.browsing(topics.reversed(), archived: true, expanded: false).map(\.id) == Array(topics.prefix(10)).map(\.id))
        #expect(TopicPlace.browsing(topics, archived: true, expanded: false, retaining: "11").count == 11)
        #expect(TopicPlace.browsing(topics, archived: true, expanded: true).count == 12)
    }

    @Test func tiesAndEmptyTopicsAreAlphabetical() {
        let tied = [TopicPlace(id: "z", name: "Zebra", count: 0), TopicPlace(id: "a", name: "apple", count: 0)]
        #expect(TopicPlace.browsing(tied, archived: false, expanded: false).map(\.id) == ["a", "z"])
        #expect(TopicPlace.matching(tied, text: " APP ").map(\.id) == ["a"])
        #expect(TopicPlace.matching(tied, text: "  ").isEmpty)
        #expect(TopicPlace.matching(tied, text: "missing").isEmpty)
    }
}
