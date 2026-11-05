import NoteBankKit
import SwiftUI

struct SelectableItemRow<Content: View>: View {
    let selection: ItemSelection
    let item: FeedItem
    var busy = false
    var onBegin: (() -> Void)?
    var onCommands: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    private func begin() {
        guard !busy, item.syncError == nil else { return }
        onBegin?()
        selection.begin(item.id)
    }

    var body: some View {
        if selection.isSelecting {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selection.ids.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selection.ids.contains(item.id) ? palette.accent : palette.lineStrong)
                    .padding(.top, 8)
                    .frame(width: onCommands == nil ? 22 : 28,
                           height: onCommands == nil ? 30 : 44, alignment: .top)
                content().padding(.trailing, 8).disabled(true).allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection.ids.contains(item.id) ? palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { if !busy && item.syncError == nil { selection.toggle(item.id) } }
            .accessibilityRepresentation {
                Button(item.label) { selection.toggle(item.id) }
                    .accessibilityValue(selection.ids.contains(item.id) ? "Selected" : "Not selected")
                    .disabled(busy || item.syncError != nil)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                content().padding(.trailing, 8)
                if let onCommands {
                    Button(action: onCommands) {
                        Image(systemName: "ellipsis").frame(width: 28, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.inkMuted)
                    .accessibilityLabel("Item actions")
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 10).onEnded { _ in begin() })
            .accessibilityAction(named: "Select", begin)
        }
    }
}

