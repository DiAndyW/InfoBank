import Testing
@testable import NoteBankKit

@MainActor struct ItemSelectionTests {
    @Test func holdEntryToggleAndLastDeselectionExit() {
        let selection = ItemSelection()
        selection.begin("a")
        #expect(selection.ids == ["a"])
        selection.toggle("b")
        #expect(selection.ids == ["a", "b"])
        selection.toggle("a")
        selection.toggle("b")
        #expect(!selection.isSelecting)
    }

    @Test func refreshDropsMissingIDsWithoutSelectingArrivalsAndPreservesOrder() {
        let selection = ItemSelection()
        selection.begin("a")
        selection.toggle("b")
        selection.reconcile(["b", "c"])
        #expect(selection.orderedIDs(in: ["c", "b"]) == ["b"])
        selection.reconcile(["c"])
        #expect(!selection.isSelecting)
    }

    @Test func batchNoticeRetainsEveryIDForOneUndo() {
        let notices = NoticeCenter()
        notices.postTrashed(itemIDs: ["a", "b"], copied: true)
        #expect(notices.current?.message == "2 Items copied, moved to Trash")
        #expect(notices.current?.action == .undoBatchTrash(["a", "b"]))
        notices.postBatchCompleted(count: 2, copied: false)
        #expect(notices.current?.message == "2 Items restored")
        #expect(notices.current?.action == nil)
    }
}
