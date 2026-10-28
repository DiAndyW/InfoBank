import NoteBankKit
import SwiftUI

struct PlacesView: View {
    let store: Store
    let wake: () -> Void
    let archived: [TopicPlace]
    @State private var showingArchived = false
    @State private var naming = false
    @State private var renameID: String?
    @State private var name = ""
    @State private var error: String?
    @State private var deleting: TopicPlace?

    private func run(_ action: () throws -> Void) {
        do { try action(); wake() }
        catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private func topicMenu(_ topic: TopicPlace, archived: Bool) -> some View {
        Button("Rename", systemImage: "pencil") { renameID = topic.id; name = topic.name; naming = true }
        Button(archived ? "Unarchive" : "Archive", systemImage: "archivebox") {
            run { try store.setTopicArchived(topic.id, archived: !archived, nowUs: Time.nowUs()) }
        }
        Button("Delete Topic…", systemImage: "trash", role: .destructive) { deleting = topic }
    }
    let places: Places
    let composer: ComposerModel
    let status: SyncStatus
    let notices: NoticeCenter
    let onShow: (String) -> Void
    let openSettings: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func row(_ place: Place, _ name: String, _ count: Int?) -> some View {
        NavigationLink(value: place) {
            HStack(spacing: 12) {
                if symbol(place) != nil {
                    Image(systemName: symbol(place) ?? "").font(.system(size: 17)).foregroundStyle(palette.inkMuted).frame(width: 22).accessibilityHidden(true)
                }
                Text(name).font(.plex(.sans, 17)).foregroundStyle(palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                Text(count.map { String($0) } ?? "").font(.plex(.mono, 13, relativeTo: .footnote)).foregroundStyle(palette.inkMuted)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.lineStrong)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func symbol(_ place: Place) -> String? {
        switch place {
        case .all: "square.3.layers.3d"
        case .inbox: "tray"
        case .tunnel: "arrow.left.arrow.right"
        case .topic: nil
        case .trash: "trash"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 20)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 8)
            Text("NoteBank")
                .font(.plex(.sansSemibold, 32, relativeTo: .largeTitle))
                .kerning(-0.32)
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            Group {
                if status.needsSettings {
                    Button(action: openSettings) { SyncStatusLine(status: status, size: 13).frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain)
                } else {
                    SyncStatusLine(status: status, size: 13).frame(minHeight: 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 0) {
                    HomeComposerView(model: composer, topics: places.topics).padding(.bottom, 20)
                    VStack(spacing: 0) {
                        row(.all, "All Items", places.allCount)
                        Divider().overlay(palette.line)
                        row(.inbox, "Inbox", places.inboxCount)
                        Divider().overlay(palette.line)
                        row(.tunnel, "Tunnel", places.tunnelCount)
                    }
                    .card()
                    HStack {
                        Text("Topics").textCase(.uppercase).kerning(0.96).accessibilityAddTraits(.isHeader).font(.plex(.sansSemibold, 12, relativeTo: .caption)).foregroundStyle(palette.inkMuted)
                        Spacer()
                        Button { renameID = nil; name = ""; naming = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("New Topic")
                    }.padding(.horizontal, 16).padding(.top, 12)
                    if !places.topics.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(places.topics) { topic in
                                if topic.id != places.topics.first?.id { Divider().overlay(palette.line) }
                                row(.topic(topic.id), topic.name, topic.count).contextMenu { topicMenu(topic, archived: false) }
                            }
                        }
                        .card()
                    }
                    Button { showingArchived.toggle() } label: {
                        HStack {
                            Text("Archived Topics")
                                .textCase(.uppercase).kerning(0.96)
                                .font(.plex(.sansSemibold, 12, relativeTo: .caption))
                                .foregroundStyle(palette.inkMuted)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showingArchived ? 90 : 0))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showingArchived)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showingArchived ? "Expanded" : "Collapsed")
                    .padding(.horizontal, 16).padding(.top, 12)
                    if showingArchived {
                        VStack(spacing: 0) {
                            ForEach(archived) { topic in
                                if topic.id != archived.first?.id { Divider().overlay(palette.line) }
                                row(.topic(topic.id), topic.name, topic.count).contextMenu { topicMenu(topic, archived: true) }
                            }
                            if archived.isEmpty {
                                Text("No archived Topics").font(.plex(.sans, 14)).foregroundStyle(palette.inkMuted).padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.card()
                    }
                    row(.trash, "Trash", nil).card().padding(.top, 20)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let notice = notices.current {
                    NoticeView(message: notice.message, actionTitle: notice.actionTitle, onAction: { if notice.action == .dismiss { notices.dismiss() } else { onShow(notice.itemID) } }, onDismiss: notices.dismiss)
                        .padding(.horizontal, 12)
                        .id(notice.id)
                }
            }
        }
        .background(palette.surfaceSidebar)
        .alert(renameID == nil ? "New Topic" : "Rename Topic", isPresented: $naming) {
            TextField("Topic name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                run {
                    if let renameID { try store.renameTopic(renameID, name: name, nowUs: Time.nowUs()) }
                    else { _ = try store.createTopic(name: name, nowUs: Time.nowUs()) }
                }
            }
        }
        .alert("Couldn't save the change", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .fullScreenCover(item: $deleting) { topic in TopicDeletionView(store: store, topic: topic, wake: wake) }
    }
}
