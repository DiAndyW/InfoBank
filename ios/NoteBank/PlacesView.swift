import NoteBankKit
import SwiftUI

struct PlacesView: View {
    let store: Store
    let wake: () -> Void
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollY: CGFloat = 0
    @State private var topicsY: CGFloat = 0
    @State private var scrollHeight: CGFloat = 0
    @State private var topicHeaderHeight: CGFloat = 0
    @State private var showAllTopics = false
    @State private var retainedTopicID: String?
    @State private var naming = false
    @State private var renameID: String?
    @State private var name = ""
    @State private var error: String?
    @State private var deleting: TopicPlace?
    @State private var deletingEmpty: TopicPlace?

    private func run(_ action: () throws -> Void) {
        do { try action(); wake() }
        catch { self.error = errorMessage(error) }
    }

    @ViewBuilder private func topicMenu(_ topic: TopicPlace) -> some View {
        Button("Rename", systemImage: "pencil") { renameID = topic.id; name = topic.name; naming = true }
        Button("Delete Topic…", systemImage: "trash", role: .destructive) {
            if topic.count == 0 { deletingEmpty = topic } else { deleting = topic }
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func row(_ place: FeedPlace, _ name: String, _ count: Int?) -> some View {
        NavigationLink(value: Route.place(place)) {
            HStack(spacing: 12) {
                if symbol(place) != nil {
                    Image(systemName: symbol(place) ?? "").font(.system(size: 17)).foregroundStyle(palette.inkMuted).frame(width: 22).accessibilityHidden(true)
                }
                Text(name).font(.plex(.sans, 17)).foregroundStyle(palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                Text(count.map { String($0) } ?? "").font(.plex(.mono, 13, relativeTo: .footnote)).foregroundStyle(palette.inkMuted)
                    .contentTransition(.identity)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.lineStrong)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlaceRowButtonStyle())
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10))
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
        TopicPlace.browsing(places.topics, expanded: showAllTopics, retaining: renameID ?? retainedTopicID)
    }

    private var topicHeader: some View {
        HStack {
            Text("Topics").textCase(.uppercase).kerning(0.96).accessibilityAddTraits(.isHeader)
                .font(.plex(.sansSemibold, 12, relativeTo: .caption)).foregroundStyle(palette.inkMuted)
            Spacer()
            if places.topics.count > 10 {
                Button {
                    if scrollY > topicsY { scrollPosition.scrollTo(y: topicsY) }
                    withTransaction(\.disablesAnimations, true) { showAllTopics.toggle() }
                } label: {
                    Text(showAllTopics ? "Show less" : "Show all")
                        .underline().font(.plex(.sans, 13)).frame(minHeight: 44)
                }
            }
            Button { renameID = nil; name = ""; naming = true } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }.accessibilityLabel("New Topic")
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
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("places")).maxY } action: { topicsY = $0 }
                    Section {
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(visibleTopics.enumerated()), id: \.element.id) { index, topic in
                                    VStack(spacing: 0) {
                                        if index > 0 { Divider().overlay(palette.line) }
                                        row(.topic(topic.id), topic.name, topic.count)
                                            .contextMenu { topicMenu(topic) }
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    .zIndex(Double(-index))
                                }
                                if visibleTopics.isEmpty {
                                    Text("No Topics yet")
                                        .font(.plex(.sans, 14)).foregroundStyle(palette.inkMuted).padding(16)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: visibleTopics.map(\.id))
                            .card().clipShape(RoundedRectangle(cornerRadius: 10))
                            row(.trash, "Trash", nil).card().clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 20)
                        }
                        .frame(minHeight: max(0, scrollHeight - topicHeaderHeight), alignment: .top)
                    } header: {
                        topicHeader.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topicHeaderHeight = $0 }
                    }
                }
                .padding(.horizontal, 16)
                .coordinateSpace(.named("places"))
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { scrollY = $1 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { scrollHeight = $1 }
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
        .emptyTopicDeletionAlert(topic: $deletingEmpty, store: store, notices: notices, wake: wake, onError: { error = $0 })
        .fullScreenCover(item: $deleting) { topic in TopicDeletionView(store: store, topic: topic, notices: notices, wake: wake) }
    }
}

private struct PlaceRowButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? palette.hover : palette.surfaceRaised)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.25), value: configuration.isPressed)
    }
}
