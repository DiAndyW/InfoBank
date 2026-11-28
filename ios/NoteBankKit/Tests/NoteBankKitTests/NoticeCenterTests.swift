import Testing
@testable import NoteBankKit

@MainActor struct NoticeCenterTests {
    private var zip: FeedAttachment {
        FeedAttachment(id: "zip", filename: "archive.zip", mimeType: "application/zip", sizeBytes: 10, uploaded: true, hasThumbnail: false, uploadError: nil)
    }

    @Test func dismissingMatchingNoticeClearsIt() {
        let center = NoticeCenter()
        let id = center.postUnsupported(zip)
        center.dismiss(id: id)
        #expect(center.current == nil)
        #expect(center.download == nil)
    }

    @Test func dismissingStaleNoticePreservesReplacement() {
        let center = NoticeCenter()
        let id = center.postUnsupported(zip)
        center.postCopiedText()
        let replacement = center.current
        center.dismiss(id: id)
        #expect(center.current == replacement)
        #expect(center.download == nil)
    }

    @Test func downloadRequestDismissesNotice() {
        let center = NoticeCenter()
        center.postUnsupported(zip)
        #expect(center.download == nil)
        center.requestDownload("zip")
        #expect(center.download?.attachmentID == "zip")
        #expect(center.current == nil)
    }

    @Test func repeatedDownloadRequestsHaveFreshIDs() {
        let center = NoticeCenter()
        center.requestDownload("zip")
        let first = center.download?.id
        center.requestDownload("zip")
        #expect(center.download?.id != first)
    }

    @Test func replacingUnsupportedNoticeDoesNotRequestDownload() {
        let center = NoticeCenter()
        center.postUnsupported(zip)
        center.postCopiedText()
        #expect(center.download == nil)
    }

    @Test func dismissingUnsupportedNoticeDoesNotRequestDownload() {
        let center = NoticeCenter()
        center.postUnsupported(zip)
        center.dismiss()
        #expect(center.download == nil)
    }

    @Test func copiedTextReplacesCurrentNotice() {
        let center = NoticeCenter()
        center.postTrashed(itemID: "item")
        let previousID = center.current?.id

        center.postCopiedText()

        #expect(center.current?.message == "Copied text")
        #expect(center.current?.itemID == "")
        #expect(center.current?.action == nil)
        #expect(center.current?.id != previousID)
    }

    @Test func copiedTextHasNoAction() {
        let center = NoticeCenter()
        center.postCopiedText()
        #expect(center.current?.action == nil)
    }
}
