import Testing
@testable import NoteBankKit

struct LinksTests {
    @Test func plainTextHasNoLinks() {
        #expect(linkify("call dentist") == [.text("call dentist")])
    }

    @Test func trailingPunctuationStaysOutsideTheLink() {
        #expect(linkify("read https://example.com/x. later") == [.text("read "), .link("https://example.com/x"), .text(". later")])
        #expect(linkify("(see http://a.io/b)") == [.text("(see "), .link("http://a.io/b"), .text(")")])
    }

    @Test func severalLinks() {
        #expect(linkify("https://a.com and https://b.com") == [.link("https://a.com"), .text(" and "), .link("https://b.com")])
    }

    @Test func onlyHTTPAndHTTPSBecomeLinks() {
        for text in ["javascript:alert(1)", "ftp://files.example.com", "file:///etc/passwd", "mailto:a@b.c"] {
            #expect(linkify(text) == [.text(text)])
        }
    }

    @Test func aClosingParenthesisStaysWhenTheLinkOpenedOne() {
        #expect(linkify("https://en.wikipedia.org/wiki/Heat_(1995_film)") == [.link("https://en.wikipedia.org/wiki/Heat_(1995_film)")])
        #expect(linkify("(see https://en.wikipedia.org/wiki/Heat_(1995_film)).") == [
            .text("(see "),
            .link("https://en.wikipedia.org/wiki/Heat_(1995_film)"),
            .text(")."),
        ])
    }
}
