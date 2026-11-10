import NoteBankKit
import SwiftUI

@main
struct SelectionChecksApp: App {
    var body: some Scene { WindowGroup { SelectionFixture() } }
}

struct SelectionFixture: View {
    @State private var batch = BatchItemActions()
    private var selection: ItemSelection { batch.selection }
    @State private var copies = 0
    @State private var commands = 0
    @State private var contentFrame = CGRect.zero
    @State private var rowFrame = CGRect.zero
    private let items: [FeedItem]

    init() {
        let store = try! Store(at: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "test.db"))
        for index in 1...30 { _ = try! store.capture(text: "Item \(index)", to: .tunnel, nowUs: Int64(index)) }
        items = try! store.items(in: .tunnel, before: nil, limit: 50).reversed()
    }

    var body: some View {
        VStack {
            Text("Copies: \(copies)")
            Text("Commands: \(commands)")
            Text("Selected: \(selection.ids.count)")
            Text("\(contentFrame.minX)").accessibilityIdentifier("content-origin")
            Text("\(contentFrame.width)").accessibilityIdentifier("content-width")
            Text("\(contentFrame.height)").accessibilityIdentifier("content-height")
            Text("\(rowFrame.maxX)").accessibilityIdentifier("row-right")
            ScrollView {
                VStack {
                    ForEach(items) { item in
                        SelectableItemRow(selection: selection, item: item, onCommands: { commands += 1 }) {
                            Button { copies += 1 } label: {
                                VStack(alignment: .leading) {
                                    Text(item.text!)
                                    if item.id == items.first?.id {
                                        Text("A longer note that wraps across several lines so the selection check verifies real content keeps its width and height when the actions move to the other side of the row.")
                                    }
                                }
                                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                        if item.id == items.first?.id { contentFrame = frame }
                                    }
                            }.buttonStyle(.plain).accessibilityLabel(item.text!)
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            if item.id == items.first?.id { rowFrame = frame }
                        }
                    }
                }
            }
        }.padding()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selection.isSelecting { BatchActionsBar(batch: batch, items: items, tunnel: true, trashAfterCopy: true) }
            }
            .environment(\.palette, Theme.paper.palette)
    }
}
