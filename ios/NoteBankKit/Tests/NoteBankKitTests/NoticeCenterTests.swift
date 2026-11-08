import Testing
@testable import NoteBankKit

@MainActor struct NoticeCenterTests {
    @Test func copiedTextReplacesCurrentNotice() {
        let center = NoticeCenter()
        center.postTrashed(itemID: "item")
        let previousID = center.current?.id

        center.postCopiedText()

        #expect(center.current?.message == "Copied text")
        #expect(center.current?.itemID == "")
        #expect(center.current?.action == .dismiss)
        #expect(center.current?.actionTitle == "Dismiss")
        #expect(center.current?.id != previousID)
    }
}
