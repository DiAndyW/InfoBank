import NoteBankKit
import SwiftUI

struct PlacesView: View {
    let store: Store
    let wake: () -> Void
    let archived: [TopicPlace]
    @State private var showingArchived = false
    @State private var showAllOpen = false
    @State private var showAllArchived = false
    @State private var retainedTopicID: String?
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
    let onUndoClear: (DraftPlace) -> Void
    let onShow: (String) -> Void
    let onSearch: () -> Void
    let openSettings: () -> Void
    @Environment(\.palette) private var palette

    private func row(_ place: FeedPlace, _ name: String, _ count: Int?) -> some View {
        NavigationLink(value: Route.place(place)) {
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

    private func symbol(_ place: FeedPlace) -> String? {
        switch place {
        case .inbox: "tray"
        case .tunnel: "arrow.left.arrow.right"
        case .topic: nil
        case .trash: "trash"
        }
    }

    private var visibleTopics: [TopicPlace] {
        TopicPlace.browsing(showingArchived ? archived : places.topics, archived: showingArchived,
                            expanded: showingArchived ? showAllArchived : showAllOpen, retaining: renameID ?? retainedTopicID)
    }

    private var topicHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Topics").textCase(.uppercase).kerning(0.96).accessibilityAddTraits(.isHeader)
                    .font(.plex(.sansSemibold, 12, relativeTo: .caption)).foregroundStyle(palette.inkMuted)
                Spacer()
                Button { showingArchived = false; renameID = nil; name = ""; naming = true } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }.accessibilityLabel("New Topic")
            }
            HStack(spacing: 24) {
                ForEach([false, true], id: \.self) { archivedView in
                    Button { showingArchived = archivedView } label: {
                        Text(archivedView ? "Archived" : "Open")
                            .font(.plex(showingArchived == archivedView ? .sansSemibold : .sans, 15))
                            .foregroundStyle(showingArchived == archivedView ? palette.accent : palette.inkMuted)
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) {
                                if showingArchived == archivedView { Rectangle().fill(palette.accent).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(showingArchived == archivedView ? .isSelected : [])
                }
                Spacer(minLength: 0)
                if (showingArchived ? archived : places.topics).count > 10 {
                    Button {
                        if showingArchived { showAllArchived.toggle() } else { showAllOpen.toggle() }
                    } label: {
                        Text((showingArchived ? showAllArchived : showAllOpen) ? "Show less" : "Show all")
                            .underline().font(.plex(.sans, 13)).frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(palette.surfaceSidebar)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Search")
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
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    HomeComposerView(model: composer, store: store, topics: places.topics, wake: wake, notices: notices).padding(.bottom, 20)
                    VStack(spacing: 0) {
                        row(.inbox, "Inbox", places.inboxCount)
                        Divider().overlay(palette.line)
                        row(.tunnel, "Tunnel", places.tunnelCount)
                    }
                    .card()
                    Section {
                        VStack(spacing: 0) {
                            ForEach(visibleTopics) { topic in
                                if topic.id != visibleTopics.first?.id { Divider().overlay(palette.line) }
                                row(.topic(topic.id), topic.name, topic.count)
                                    .contextMenu { topicMenu(topic, archived: showingArchived) }
                            }
                            if visibleTopics.isEmpty {
                                Text(showingArchived ? "No archived Topics" : "No Topics yet")
                                    .font(.plex(.sans, 14)).foregroundStyle(palette.inkMuted).padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.card()
                    } header: { topicHeader }
                    row(.trash, "Trash", nil).card().padding(.top, 20)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .bottom) {
            ItemNoticeView(notices: notices, store: store, wake: wake, onShow: onShow, onError: { error = $0 }, onUndoClear: onUndoClear)
        }
        .contentShape(.rect)
        .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        .containerBackground(palette.surfaceSidebar, for: .navigation)
        .alert(renameID == nil ? "New Topic" : "Rename Topic", isPresented: $naming) {
            TextField("Topic name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                run {
                    if let renameID { try store.renameTopic(renameID, name: name, nowUs: Time.nowUs()) }
                    else { retainedTopicID = try store.createTopic(name: name, nowUs: Time.nowUs()) }
                }
            }
        }
        .alert("Couldn't save the change", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .fullScreenCover(item: $deleting) { topic in TopicDeletionView(store: store, topic: topic, wake: wake) }
    }
}
