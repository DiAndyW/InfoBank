import NoteBankKit
import SwiftUI

struct ItemActionsView: View {
    let item: FeedItem
    let store: Store
    var place: Place = .inbox
    var trashAfterCopy: Bool? = false
    enum Copy { case item(Bool?), text }
    let onCopy: (Copy) -> Void
    let onEdit: (String) -> Void
    let onChanged: (_ trashed: Bool, _ moved: Bool) -> Void

    private enum Page { case commands, move, conflict }
    @State private var page = Page.commands
    @State private var topics: [TopicPlace] = []
    @State private var error: String?
    @State private var discard = false
    @State private var naming = false
    let onDismiss: () -> Void
    @Binding var expanded: Bool
    @Binding var actionError: String?
    @Environment(\.palette) private var palette

    private func run(_ action: () throws -> Void) {
        do { try action(); onDismiss() } catch { self.error = errorMessage(error) }
    }

    private func move(_ destination: Destination) {
        run {
            try store.move(itemID: item.id, to: destination, nowUs: Time.nowUs())
            onChanged(false, true)
        }
    }

    private var copy: CopyActions { CopyActions(place: place, hasText: item.text != nil, trashAfterCopy: trashAfterCopy) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = error ?? actionError {
                    Text(error).foregroundStyle(palette.danger).padding()
                        .accessibilityAddTraits(.isStaticText)
                }
                switch page {
                case .commands:
                    List {
                        Group {
                        if item.syncError != nil {
                            ForEach(copy.menu, id: \.kind) { action in
                                Button(action.label, systemImage: "doc.on.doc") {
                                    onCopy(action.kind == .text ? .text : .item(trashAfterCopy))
                                }
                            }
                            Button("Discard…", systemImage: "trash", role: .destructive) { discard = true }
                        } else {
                            if item.conflict != nil {
                                Button("Resolve text conflict", systemImage: "exclamationmark.bubble") { page = .conflict }
                            }
                            ForEach(copy.itemCommands, id: \.self) { command in
                                switch command {
                                case "edit":
                                    Button("Edit", systemImage: "pencil") { onEdit(item.conflict?.mine == true ? item.conflict?.text ?? "" : item.text ?? "") }
                                case "move":
                                    Button("Move to…", systemImage: "folder") {
                                        do { topics = try store.places().topics; page = .move }
                                        catch { self.error = errorMessage(error) }
                                    }
                                case "trash":
                                    Section {
                                        Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                            run {
                                                try store.trash(itemID: item.id, nowUs: Time.nowUs())
                                                onChanged(true, false)
                                            }
                                        }
                                    }
                                default:
                                    if let action = copy.menu.first(where: { "copy_\($0.kind.rawValue)" == command }) {
                                        Button(action.label, systemImage: "doc.on.doc") {
                                            onCopy(action.kind == .text ? .text : .item(trashAfterCopy))
                                        }
                                    }
                                }
                            }
                        }
                        }.themedSheetRow()
                    }.themedSheetList()
                case .move:
                    List {
                        Group {
                        destination("Inbox", .inbox)
                        destination("Tunnel", .tunnel)
                        Section("Topics") {
                            Button("New Topic…", systemImage: "plus") { naming = true }
                            ForEach(topics) { topic in destination(topic.name, .topic(topic.id)) }
                        }
                        }.themedSheetRow()
                    }.themedSheetList()
                case .conflict:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Both Devices changed this text. Choose which version to keep, or edit yours.")
                            Text("Mine").font(.headline)
                            Text(item.conflict?.mine == true ? item.conflict?.text ?? "(No text)" : item.text ?? "(No text)")
                                .textSelection(.enabled)
                            Text("Server").font(.headline)
                            Text(item.conflict?.mine == true ? item.text ?? "(No text)" : item.conflict?.text ?? "(No text)")
                                .textSelection(.enabled)
                            Button("Keep mine") { resolve(true) }
                            Button("Use Server") { resolve(false) }
                            Button("Edit mine") {
                                onEdit(item.conflict?.mine == true ? item.conflict?.text ?? "" : item.text ?? "")
                            }
                        }.padding()
                    }
                }
            }
            .foregroundStyle(palette.ink)
            .themedSheet()
            .navigationTitle(page == .commands ? "Item actions" : page == .move ? "Move to…" : "Text conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(page == .commands ? "Done" : "Cancel") {
                        if page == .commands { onDismiss() } else { error = nil; page = .commands }
                    }
                }
            }
        }
        .themedSheet()
        .onChange(of: page) { _, page in expanded = page != .commands }
        .newTopicDialog(isPresented: $naming) { name in
            try? store.pickerTopicProblem(named: name)
        } create: { name in
            move(.topic(try store.pickerTopic(named: name, nowUs: Time.nowUs())))
        }
        .alert("Discard this Item?", isPresented: $discard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { run { try store.discard(itemID: item.id); onChanged(false, false) } }
        } message: { Text("This Item is only on this iPhone. Discarding deletes it here, with no Trash or Undo.") }
    }

    private func destination(_ title: String, _ destination: Destination) -> some View {
        Button { move(destination) } label: {
            HStack {
                Text(title)
                Spacer()
                if destination == item.destination {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func resolve(_ mine: Bool) {
        run {
            let trashed = try store.resolveTextConflict(itemID: item.id, keepMine: mine, nowUs: Time.nowUs())
            onChanged(trashed, false)
        }
    }
}
