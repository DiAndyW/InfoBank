import NoteBankKit
import SwiftUI

struct SelectableItemRow<Content: View>: View {
    let selection: ItemSelection
    let item: FeedItem
    var busy = false
    var onCommands: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette
    @Environment(\.ruledLine) private var ruledLine

    var body: some View {
        if selection.isSelecting {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selection.ids.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selection.ids.contains(item.id) ? palette.accent : palette.lineStrong)
                    .padding(.top, ruledLine == nil ? 8 : 0)
                    .frame(width: onCommands == nil ? 22 : 28,
                           height: ruledLine ?? (onCommands == nil ? 30 : 44),
                           alignment: ruledLine == nil ? .top : .center)
                content().padding(.trailing, 8).disabled(true).allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(selection.ids.contains(item.id) ? palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
            .onTapGesture { if !busy && item.syncError == nil { selection.toggle(item.id) } }
            .accessibilityRepresentation {
                Button(item.label) { selection.toggle(item.id) }
                    .accessibilityValue(selection.ids.contains(item.id) ? "Selected" : "Not selected")
                    .disabled(busy || item.syncError != nil)
            }
        } else {
            content()
                .padding(.trailing, 8)
                .contentShape(Rectangle())
                .highPriorityGesture(onCommands.map { commands in
                    LongPressGesture(minimumDuration: 0.35, maximumDistance: 10).onEnded { _ in commands() }
                })
        }
    }
}
