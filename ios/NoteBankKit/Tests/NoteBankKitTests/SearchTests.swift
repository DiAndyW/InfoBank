import Foundation
import GRDB
import Testing
@testable import NoteBankKit

struct SearchTests {
    private func put(_ store: Store, _ id: String, _ text: String?, topic: String? = nil, at captureTimeUs: Int64 = 1, files: [String] = []) throws {
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO items (id, topic_id, text, capture_time) VALUES (?, ?, ?, ?)", arguments: [id, topic, text, captureTimeUs])
            for (index, name) in files.enumerated() {
                try db.execute(
                    sql: "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?, ?, ?, 'application/pdf', 1, 1, 0)",
                    arguments: ["\(id)-f\(index)", id, name])
            }
        }
    }

    private func ids(_ store: Store, _ query: SearchQuery, before cursor: FeedCursor? = nil, limit: Int = 50) throws -> [String] {
        try store.search(query, before: cursor, limit: limit).map(\.id)
    }

    @Test func wordsMatchAnywhereIgnoringCaseAndAccents() throws {
        let (store, _) = try tempStore()
        try put(store, "mid", "a screenshot of it", at: 1)
        try put(store, "accent", "paid the Café bill", at: 2)
        try put(store, "cjk", "截图保存好了", at: 3)
        try put(store, "file", nil, files: ["Invoice_2026.pdf"])
        try put(store, "other", "nothing here", at: 0)
        #expect(try ids(store, SearchQuery(text: "SHOT")) == ["mid"])
        #expect(try ids(store, SearchQuery(text: "cafe")) == ["accent"])
        #expect(try ids(store, SearchQuery(text: "保存好")) == ["cjk"])
        #expect(try ids(store, SearchQuery(text: "voice_20")) == ["file"])
    }

    @Test func everyWordMustMatchAndShortWordsCount() throws {
        let (store, _) = try tempStore()
        try put(store, "both", "AI notes for March", at: 2)
        try put(store, "one", "notes for April", at: 1)
        #expect(try ids(store, SearchQuery(text: "notes march")) == ["both"])
        #expect(try ids(store, SearchQuery(text: "ai notes")) == ["both"])
        #expect(try ids(store, SearchQuery(text: "ai")) == ["both"])
    }

    @Test func typedSyntaxIsLiteral() throws {
        let (store, _) = try tempStore()
        let tokens = ["\"", "\"\"\"", "*", "a-b", "AND", "(x", "NEAR", "%"]
        for (index, token) in tokens.enumerated() {
            try put(store, "token\(index)", "has \(token) inside", at: Int64(index + 1))
        }
        try put(store, "control", "say hi to xy a b 50 plain", at: 0)
        for (index, token) in tokens.enumerated() {
            let found = try store.search(SearchQuery(text: token), before: nil, limit: 50)
            #expect(found.contains { $0.id == "token\(index)" }, "searching \(token)")
            #expect(found.allSatisfy { $0.item.text!.localizedCaseInsensitiveContains(token) }, "searching \(token)")
        }
    }

    @Test func filtersNarrowResults() throws {
        let (store, _) = try tempStore()
        try store.pool.write { try $0.execute(sql: "INSERT INTO topics (id, name) VALUES ('t', 'Taxes'), ('old', 'Old')") }
        try put(store, "inbox", "note one", at: 10)
        try put(store, "taxes", "note two", topic: "t", at: 20, files: ["a.pdf"])
        try put(store, "edge", "note edge", at: 29)
        try put(store, "older", "note three", topic: "old", at: 30)
        try put(store, "trashed", "note four", at: 40)
        try put(store, "tunnel", "note five", at: 50)
        try store.pool.write { try $0.execute(sql: "UPDATE items SET deleted_at = 41 WHERE id = 'trashed'; UPDATE items SET in_tunnel = 1 WHERE id = 'tunnel'") }

        func with(_ change: (inout SearchQuery) -> Void) throws -> [String] {
            var query = SearchQuery(text: "note")
            change(&query)
            return try ids(store, query)
        }
        #expect(try with { _ in } == ["tunnel", "older", "edge", "taxes", "inbox"])
        #expect(try with { $0.place = .inbox } == ["edge", "inbox"])
        #expect(try with { $0.place = .tunnel } == ["tunnel"])
        #expect(try with { $0.place = .topic("old") } == ["older"])
        #expect(try with { $0.hasFiles = true } == ["taxes"])
        #expect(try with { $0.fromUs = 20; $0.toUs = 30 } == ["edge", "taxes"])

    }

    @Test func pagesWithTheCursor() throws {
        let (store, _) = try tempStore()
        try put(store, "a", "same words", at: 1)
        try put(store, "b", "same words", at: 1)
        try put(store, "c", "same words", at: 1)
        let first = try store.search(SearchQuery(text: "same"), before: nil, limit: 2)
        #expect(first.map(\.id) == ["c", "b"])
        #expect(try ids(store, SearchQuery(text: "same"), before: first.last!.item.cursor, limit: 2) == ["a"])
    }

    @Test func marksWrapMatchesInTextAndTheRightFilename() throws {
        let (store, _) = try tempStore()
        try put(store, "i", "paid the Invoice", files: ["notes.txt", "Invoice_2026.pdf"])
        let found = try store.search(SearchQuery(text: "invoice"), before: nil, limit: 10)
        #expect(found[0].markedText == "paid the \u{E000}Invoice\u{E001}")
        #expect(found[0].markedFilenames == ["notes.txt", "\u{E000}Invoice\u{E001}_2026.pdf"])

        let short = try store.search(SearchQuery(text: "pa"), before: nil, limit: 10)
        #expect(short[0].markedText == "paid the Invoice")
        #expect(short[0].markedFilenames == ["notes.txt", "Invoice_2026.pdf"])

        try put(store, "files-only", nil, at: 2, files: ["invoice.pdf"])
        let fileOnly = try store.search(SearchQuery(text: "invoice"), before: nil, limit: 10)
        #expect(fileOnly[0].markedText == nil)
        #expect(fileOnly[0].markedFilenames == ["\u{E000}invoice\u{E001}.pdf"])
    }

    @Test func shortWordsMatchFileNamesOfAnItemWithoutText() throws {
        let (store, _) = try tempStore()
        try put(store, "i", nil, files: ["notes.txt", "other.png"])
        try put(store, "other", nil, at: 2, files: ["notes.txt"])
        let found = try store.search(SearchQuery(text: "pn"), before: nil, limit: 10)
        #expect(found.map(\.id) == ["i"])
        let match = try #require(found.first)
        #expect(match.markedText == nil)
        #expect(match.markedFilenames == ["notes.txt", "other.png"])
    }

    @Test func wordLengthCountsCodePointsLikeTheIndex() throws {
        let (store, _) = try tempStore()
        let couple = "\u{1F468}\u{200D}\u{1F469}"
        #expect(couple.count == 1 && couple.unicodeScalars.count == 3)
        try put(store, "i", "see \(couple) here")
        let found = try store.search(SearchQuery(text: couple), before: nil, limit: 10)
        #expect(found.map(\.id) == ["i"])
        #expect(found[0].markedText == "see \u{E000}\(couple)\u{E001} here")
    }

    @Test func searchMarksMapsToPlainText() {
        let (plain, ranges) = searchMarks("a\u{E000}bc\u{E001}d\u{E000}e\u{E001}")
        #expect(plain == "abcde")
        #expect(ranges.map { String(plain[$0]) } == ["bc", "e"])
    }

    @Test func blankQueryThrows() throws {
        let (store, _) = try tempStore()
        #expect(throws: SearchError.self) { try store.search(SearchQuery(text: "  \n "), before: nil, limit: 10) }
    }
}
