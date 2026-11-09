import NoteBankKit
import SwiftUI

struct TopicDeletionView: View {
    let store: Store
    let topic: TopicPlace
    let wake: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var selecting = false
    @State private var items: [FeedItem] = []
    @State private var cursors: [FeedCursor?] = [nil]
    @State private var next: FeedCursor?
    @State private var kept: Set<String> = []
    @State private var confirm = false
    @State private var keep: TopicKeep = .all
    @State private var error: String?

    private func load() {
        do {
            let page = try store.items(in: .topic(topic.id), before: cursors.last ?? nil, limit: 51)
            items = Array(page.prefix(50))
            next = page.count > 50 ? items.last?.cursor : nil
        } catch { self.error = errorMessage(error) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Text(error).foregroundStyle(palette.danger) }
                if selecting {
                    Text("Checked Items are kept in Inbox. Unchecked Items move to Trash.").font(.plex(.sans, 15))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { item in
                                HStack(alignment: .top) {
                                    Button {
                                        if kept.contains(item.id) { kept.remove(item.id) } else { kept.insert(item.id) }
                                    } label: { Image(systemName: kept.contains(item.id) ? "checkmark.square.fill" : "square").frame(width: 44, height: 44) }
                                    .accessibilityLabel("Keep \(item.label)")
                                    .accessibilityValue(kept.contains(item.id) ? "Selected" : "Not selected")
                                    ItemRow(item: item, showsTopic: false, highlighted: false, copyable: false, copied: false, onCopy: {}, onCommands: {})
                                }
                            }
                        }
                    }
                    HStack {
                        Button("Previous") { cursors.removeLast(); load() }.disabled(cursors.count == 1)
                        Spacer()
                        Text("Page \(cursors.count)").font(.plex(.mono, 12))
                        Spacer()
                        Button("Next") { cursors.append(next); load() }.disabled(next == nil)
                    }
                    Text("\(kept.count) selected to keep").font(.plex(.sans, 13))
                    Button("Review deletion…", role: .destructive) { keep = .only(kept); confirm = true }
                } else {
                    Text("Delete “\(topic.name)”?").font(.plex(.sansSemibold, 22))
                    Text("Choose what happens to its Items.").font(.plex(.sans, 16))
                    Button("Keep all in Inbox") { keep = .all; confirm = true }
                    Button("Move all to Trash", role: .destructive) { keep = .none; confirm = true }
                    Button("Select manually…") { selecting = true; load() }
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(palette.ink)
            .background(palette.surface)
            .navigationTitle(selecting ? "Keep Items" : "Delete Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Delete this Topic?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Topic", role: .destructive) {
                    do { try store.deleteTopic(topic.id, keeping: keep, nowUs: Time.nowUs()); wake(); dismiss() }
                    catch { self.error = errorMessage(error) }
                }
            } message: {
                switch keep {
                case .all: Text("Its Items will move to Inbox.")
                case .none: Text("Its Items will move to Trash.")
                case .only: Text("Checked Items will move to Inbox. All other Items currently in this Topic will move to Trash, including any received while selecting.")
                }
            }
        }
    }
}
