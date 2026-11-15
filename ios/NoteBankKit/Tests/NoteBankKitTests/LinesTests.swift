import Testing
@testable import NoteBankKit

struct LinesTests {
    @Test func roundsUpToWholeLines() {
        #expect(wholeLines(26, line: 26) == 26)
        #expect(wholeLines(26.004, line: 26) == 26)
        #expect(wholeLines(27, line: 26) == 52)
        #expect(wholeLines(0, line: 26) == 26)
        #expect(wholeLines(155.999, line: 26) == 156)
        #expect(wholeLines(61, line: 41.5) == 83)
    }
}
