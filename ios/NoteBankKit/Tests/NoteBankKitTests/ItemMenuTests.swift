import Testing
@testable import NoteBankKit

struct ItemMenuTests {
    @Test func orderRetainsCopyAvailability() throws {
        let rule = try Behaviour.rule("item.menu")
        for place in [Place.inbox, .topic("t"), .tunnel] {
            for hasText in [false, true] {
                for preference in [nil, false, true] as [Bool?] {
                    let copy = CopyActions(place: place, hasText: hasText, trashAfterCopy: preference)
                    let available = ["edit", "move"] + copy.menu.map { "copy_\($0.kind.rawValue)" } + ["trash"]
                    #expect(copy.itemCommands == rule.actions!.filter { available.contains($0) })
                }
            }
        }
    }
}
