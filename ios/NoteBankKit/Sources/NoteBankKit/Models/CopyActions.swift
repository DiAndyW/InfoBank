public struct CopyActions {
    public static let copyLabel = "Copy"
    public struct Action: Equatable, Sendable {
        public enum Kind: String, Sendable { case item, text, items }
        public let kind: Kind
        public let label: String
    }

    public let menu: [Action]
    public let row: Bool
    public let batch: [Action]
    public let attachment: [Action] = []

    public init(place: Place, hasText: Bool, trashAfterCopy: Bool? = false) {
        let trashes = place == .tunnel && trashAfterCopy == true
        row = place == .tunnel
        menu = (place == .tunnel ? [Action(kind: .item, label: trashes ? "Copy & Trash" : "Copy Item")] : [])
            + (place != .trash && place != .all && hasText ? [Action(kind: .text, label: "Copy Text")] : [])
        batch = place == .trash ? [] : [Action(kind: .items, label: trashes ? "Copy & Trash" : Self.copyLabel)]
    }
}
