import NoteBankKit
import SwiftUI

struct ItemActionsView: View {
    let item: FeedItem
    let store: Store
    var place: Place = .inbox
    var trashAfterCopy: Bool? = false
    var onSelect: (() -> Void)?
    enum Copy { case item(Bool?), text }
    let onCopy: (Copy) -> Void
    let onChanged: (_ trashed: Bool, _ moved: Bool) -> Void

    private enum Page { case commands, edit, move, conflict }
    @State private var page = Page.commands
    @State private var text = ""
    @State private var topics: [TopicPlace] = []
    @State private var error: String?
    @State private var discard = false
    @State private var naming = false
    @State private var imports: ComposerModel?
    @State private var removed: Set<String> = []

    private func beginEdit(_ value: String) {
        text = value
        removed = []
        if imports == nil { imports = ComposerModel(store: store, destination: .inbox, placeholder: "", onCaptured: {}) }
        page = .edit
    }

    private func discardImports() {
        guard let imports else { return }
        for attachment in imports.attachments { imports.removeAttachment(attachment.id) }
        removed = []
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private func run(_ action: () throws -> Void) {
        do { try action(); dismiss() } catch { self.error = errorMessage(error) }
    }

    private func move(_ destination: Destination) {
        run {
            try store.move(itemID: item.id, to: destination, nowUs: Time.nowUs())
            onChanged(false, true)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(error).foregroundStyle(palette.danger).padding()
                        .accessibilityAddTraits(.isStaticText)
                }
                switch page {
                case .commands:
                    List {
                        if let onSelect, item.syncError == nil { Button("Select", systemImage: "checkmark.circle", action: onSelect) }
                        ForEach(CopyActions(place: place, hasText: item.text != nil, trashAfterCopy: trashAfterCopy).menu, id: \.kind) { action in
                            Button(action.label, systemImage: "doc.on.doc") {
                                onCopy(action.kind == .text ? .text : .item(trashAfterCopy))
                            }
                        }
                        if item.syncError != nil {
                            Button("Discard…", systemImage: "trash", role: .destructive) { discard = true }
                        } else {
                            if item.conflict != nil {
                                Button("Resolve text conflict", systemImage: "exclamationmark.bubble") { page = .conflict }
                            }
                            Button("Edit", systemImage: "pencil") { beginEdit(item.conflict?.mine == true ? item.conflict?.text ?? "" : item.text ?? "") }
                            Button("Move to…", systemImage: "folder") {
                                do { topics = try store.places().topics; page = .move }
                                catch { self.error = errorMessage(error) }
                            }
                            Section {
                                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                                    run {
                                        try store.trash(itemID: item.id, nowUs: Time.nowUs())
                                        onChanged(true, false)
                                    }
                                }
                            }
                        }
                    }
                case .edit:
                    TextEditor(text: $text)
                        .font(.plex(.serif, 17))
                        .scrollContentBackground(.hidden)
                        .padding()
                        .accessibilityLabel("Edit text")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(item.attachments.filter { !removed.contains($0.id) }) { attachment in
                                HStack {
                                    AttachmentView(attachment: attachment)
                                    Button { removed.insert(attachment.id) } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }
                                        .accessibilityLabel("Remove \(attachment.filename)")
                                }
                            }
                            if let imports {
                                StagedAttachmentsView(model: imports)
                                AttachmentPicker(model: imports)
                                if let error = imports.error { Text(error).foregroundStyle(palette.danger) }
                            }
                        }.padding(.horizontal)
                    }
                    .containerRelativeFrame(.vertical) { height, _ in height * 0.35 }
                case .move:
                    List {
                        destination("Inbox", .inbox)
                        destination("Tunnel", .tunnel)
                        Section("Topics") {
                            Button("New Topic…", systemImage: "plus") { naming = true }
                            ForEach(topics) { topic in destination(topic.name, .topic(topic.id)) }
                        }
                    }
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
                                beginEdit(item.conflict?.mine == true ? item.conflict?.text ?? "" : item.text ?? "")
                            }
                        }.padding()
                    }
                }
            }
            .foregroundStyle(palette.ink)
            .background(palette.surface)
            .tint(palette.accent)
            .navigationTitle(page == .commands ? "Item actions" : page == .edit ? "Edit Item" : page == .move ? "Move to…" : "Text conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(page == .commands ? "Done" : "Cancel") {
                        if page == .commands { dismiss() } else { discardImports(); error = nil; page = .commands }
                    }
                    .disabled(imports?.isImporting == true)
                }
                if page == .edit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            run {
                                let trashed = try store.editItem(itemID: item.id, text: text, baseRev: item.editBase, adding: imports?.attachments.map(\.id) ?? [], removing: removed, nowUs: Time.nowUs())
                                onChanged(trashed, false)
                            }
                        }
                        .disabled(imports?.isImporting == true)
                    }
                }
            }
        }
        .interactiveDismissDisabled(imports?.isImporting == true)
        .onDisappear { discardImports() }
        .presentationDetents(page == .commands ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
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
