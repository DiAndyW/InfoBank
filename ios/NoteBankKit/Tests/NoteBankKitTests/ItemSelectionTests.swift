import Testing
@testable import NoteBankKit

@MainActor struct ItemSelectionTests {
    @Test func enterSelectsNothingAndStaysSelecting() {
        let s = ItemSelection(); s.enter()
        #expect(s.isSelecting && s.ids.isEmpty)
    }
    @Test func deselectingTheLastItemExits() {
        let s = ItemSelection(); s.enter(); s.toggle("a"); s.toggle("b"); s.toggle("a")
        #expect(s.isSelecting); s.toggle("b"); #expect(!s.isSelecting)
    }
    @Test func reconcileExitsOnlyWhenItRemovedTheLastChosenItem() {
        let s = ItemSelection(); s.enter(); s.reconcile(["x"]); #expect(s.isSelecting)
        s.toggle("a"); s.reconcile(["x"]); #expect(!s.isSelecting && s.ids.isEmpty)
    }
    @Test func clearExits() {
        let s = ItemSelection(); s.enter(); s.toggle("a"); s.clear()
        #expect(!s.isSelecting && s.ids.isEmpty)
    }

    @Test func explicitEntryToggleAndLastDeselectionExit() {
        let selection = ItemSelection()
        selection.enter()
        selection.toggle("a")
        #expect(selection.ids == ["a"])
        selection.toggle("b")
        #expect(selection.ids == ["a", "b"])
        selection.toggle("a")
        selection.toggle("b")
        #expect(!selection.isSelecting)
    }

    @Test func refreshDropsMissingIDsWithoutSelectingArrivalsAndPreservesOrder() {
        let selection = ItemSelection()
        selection.enter()
        selection.toggle("a")
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
