import NoteBankKit
import SwiftUI

struct ShowTarget: Equatable {
    let place: Place
    let itemID: String
}

struct FeedView: View {
    private let store: Store
    private let transfers: AttachmentTransfers
    let place: Place
    let status: SyncStatus
    let openSettings: () -> Void
    let notices: NoticeCenter
    let onShow: (String) -> Void
    let foregrounds: Int
    let wake: () -> Void
    @Binding var target: ShowTarget?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @State private var model: FeedModel
    @State private var composer: ComposerModel
    @State private var highlighted: String?
    @State private var visible = false
    @State private var scrollsToNewest = false
    @State private var pendingReveal: String?
    @State private var title: String
    @State private var copiedID: String?
    @State private var copyTask: Task<Void, Never>?
    @State private var copies = 0
    @State private var commands: FeedItem?
    @State private var copyAfterSheet: FeedItem?
    @State private var actionError: String?
    @State private var asking: FeedItem?
    @State private var renameTopic = false
    @State private var topicNameDraft = ""
    @State private var deleteTopic = false

    init(
        place: Place, topicName: String?, services: Services, status: SyncStatus, openSettings: @escaping () -> Void,
        onShow: @escaping (String) -> Void, foregrounds: Int, target: Binding<ShowTarget?>
    ) {
        self.store = services.store
        self.transfers = services.transfers
        self.place = place
        self.status = status
        self.openSettings = openSettings
        self.notices = services.notices
        self.onShow = onShow
        self.foregrounds = foregrounds
        wake = services.wake
        _target = target
        let title = switch place {
        case .all: "All Items"
        case .trash: "Trash"
        case .inbox: "Inbox"
        case .tunnel: "Tunnel"
        case .topic: topicName ?? ""
        }
        _title = State(wrappedValue: title)
        _model = State(wrappedValue: FeedModel(store: services.store, place: place))
        let destination: Destination = switch place {
        case .all, .inbox, .trash: .inbox
        case .tunnel: .tunnel
        case .topic(let id): .topic(id)
        }
        let placeholder = switch place {
        case .tunnel: "Send to your other devices…"
        case .topic: "Capture to \(topicName ?? "")"
        default: "Capture to the Inbox"
        }
        _composer = State(wrappedValue: ComposerModel(store: services.store, destination: destination, placeholder: placeholder, onCaptured: services.wake))
    }

    private var searchPlace: SearchPlace? {
        switch place {
        case .all: .all
        case .inbox: .inbox
        case .tunnel: .tunnel
        case .topic(let id): .topic(id)
        case .trash: nil
        }
    }

    private func revealTarget(_ proxy: ScrollViewProxy) {
        // A covered Feed of the same Place must not take the target from the one on top.
        guard visible, let shown = target, shown.place == place else { return }
        target = nil
        if model.reveal(shown.itemID) { pendingReveal = shown.itemID }
    }

    private var days: [(start: Date, items: [FeedItem])] {
        var days: [(start: Date, items: [FeedItem])] = []
        for item in model.items {
            let start = Calendar.current.startOfDay(for: item.date)
            if days.last?.start == start {
                days[days.count - 1].items.append(item)
            } else {
                days.append((start, [item]))
            }
        }
        return days
    }

    private var loadMore: some View {
        ProgressView().frame(maxWidth: .infinity).onScrollVisibilityChange { shown in
            if shown { model.loadOlder() }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(palette.line).frame(height: 1)
            Text(title).font(.plex(.sansSemibold, 12, relativeTo: .caption)).foregroundStyle(palette.inkMuted)
            Rectangle().fill(palette.line).frame(height: 1)
        }.padding(.top, 14).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
    }

    private func itemRow(_ item: FeedItem) -> some View {
        ItemRow(item: item, showsTopic: place == .all || place == .trash, highlighted: highlighted == item.id,
                copyable: place == .tunnel, copied: copiedID == item.id,
                onCopy: { copy(item) }, onCommands: { commands = item }, inTrash: place == .trash)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func copy(_ item: FeedItem) {
        guard copyTask == nil, item.syncError == nil else { return }
        copyTask = Task { @MainActor in
            defer { copyTask = nil }
            do {
                let files = try await transfers.clipboardFiles(item.attachments.map(\.id))
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { return }
                guard let current = model.items.first(where: { $0.id == item.id }),
                      current.text == item.text, current.attachments == item.attachments else {
                    throw AttachmentError("The Item changed while preparing the copy; copy it again")
                }
                let providers = try ItemClipboard.providers(text: item.text, attachments: zip(item.attachments, files).map {
                    (file: $0.1, mimeType: $0.0.mimeType)
                })
                guard !providers.isEmpty else { throw AttachmentError("This Item is empty") }
                let board = UIPasteboard.general
                let previous = board.changeCount
                board.setItemProviders(providers, localOnly: false, expirationDate: Date().addingTimeInterval(7 * 24 * 3600))
                guard board.changeCount != previous, board.numberOfItems == providers.count else {
                    throw AttachmentError("Couldn't copy the complete Item")
                }
                copies += 1
                let outcome = model.copied(item)
                if outcome == .trashed {
                    copiedID = nil
                    notices.postTrashed(itemID: item.id)
                } else { copiedID = item.id }
                if outcome == .ask { asking = item }
                wake()
            } catch is CancellationError {
            } catch { actionError = error.localizedDescription }
        }
    }

    private func answer(_ on: Bool, _ item: FeedItem) {
        let saved = model.answerTrashAfterCopy(on, item: item)
        if saved && on { notices.postTrashed(itemID: item.id) }
        wake()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.hasOlder && place != .trash { loadMore }
                    if let error = model.loadError {
                        Text(error).font(.plex(.sansMedium, 13, relativeTo: .footnote)).foregroundStyle(palette.danger)
                    }
                    if place == .trash {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let groups = TrashGroup.group(model.items, nowUs: Int64(context.date.timeIntervalSince1970 * 1_000_000))
                            ForEach(groups) { group in
                                sectionHeader(group.title)
                                ForEach(group.items) { item in itemRow(item) }
                            }
                        }
                    } else {
                        ForEach(days, id: \.start) { day in
                            sectionHeader(Calendar.current.isDateInToday(day.start) ? "Today" : day.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            ForEach(day.items) { item in itemRow(item) }
                        }
                    }
                    if model.hasOlder && place == .trash { loadMore }
                    if model.items.isEmpty && model.loadError == nil {
                        Text(place == .trash ? "Trash is empty" : "No Items yet")
                            .font(.plex(.sans, 15)).foregroundStyle(palette.inkMuted)
                            .frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.items.map(\.id))
            .defaultScrollAnchor(place == .trash ? .top : .bottom)
            .background(palette.surface)
            .onChange(of: model.items.last?.id) { _, newest in
                guard scrollsToNewest, let newest else { return }
                scrollsToNewest = false
                withAnimation { proxy.scrollTo(newest, anchor: .bottom) }
            }
            .onChange(of: pendingReveal) { _, id in
                guard let id else { return }
                pendingReveal = nil
                highlighted = id
                withAnimation { proxy.scrollTo(id, anchor: .center) } completion: {
                    withAnimation(.easeOut(duration: 1.5)) { highlighted = nil }
                }
            }
            .onChange(of: foregrounds) { model.reload() }
            .onChange(of: target, initial: true) { revealTarget(proxy) }
            .onAppear {
                visible = true
                revealTarget(proxy)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let notice = notices.current {
                    NoticeView(
                        message: notice.message, actionTitle: notice.actionTitle,
                        onAction: {
                            do {
                                switch notice.action {
                                case .undoTrash: try store.restore(itemID: notice.itemID, nowUs: Time.nowUs())
                                case .undoMove(let destination): try store.move(itemID: notice.itemID, to: destination, nowUs: Time.nowUs())
                                case .show: onShow(notice.itemID); return
                                case .dismiss: notices.dismiss(); return
                                }
                                model.reload()
                                notices.dismiss()
                                wake()
                            } catch { actionError = error.localizedDescription }
                        },
                        onDismiss: notices.dismiss)
                        .id(notice.id)
                }
                if place != .all && place != .trash && !model.topicUnavailable {
                    ComposerView(model: composer) {
                        scrollsToNewest = true
                        model.reload()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.surface)
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
        .sheet(item: $commands, onDismiss: {
            if let item = copyAfterSheet {
                copyAfterSheet = nil
                if place == .tunnel { copy(item) }
                else if let text = item.text { UIPasteboard.general.string = text }
            }
        }) { item in
            if place == .trash {
                NavigationStack {
                    List {
                        Button("Restore", systemImage: "arrow.uturn.backward") {
                            do {
                                try store.restore(itemID: item.id, nowUs: Time.nowUs())
                                notices.postRestored(itemID: item.id)
                                commands = nil
                                model.reload()
                                wake()
                            } catch { actionError = error.localizedDescription }
                        }
                    }
                    .navigationTitle("Item actions")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { commands = nil } } }
                }.presentationDetents([.medium])
            } else {
            ItemActionsView(item: item, store: store, copiesWholeItem: place == .tunnel, onCopy: {
                copyAfterSheet = item
                commands = nil
            }, onChanged: { trashed, moved in
                model.reload()
                if trashed { notices.postTrashed(itemID: item.id, copied: false) }
                if moved { notices.postMoved(itemID: item.id, from: item.destination) }
                wake()
            })
            }
        }
        .alert("Couldn't finish the action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .task(id: copies) {
            guard copiedID != nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copiedID = nil
        }
        .sensoryFeedback(.impact(weight: .light), trigger: copies)
        .alert(
            "Move Tunnel notes to Trash after you copy them?",
            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
            presenting: asking
        ) { item in
            Button("Turn on") { answer(true, item) }
            Button("Not now", role: .cancel) { answer(false, item) }
        }
        .onDisappear {
            visible = false
            copyTask?.cancel()
            if let notice = notices.current, notice.action != .show { notices.dismiss() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert("Rename Topic", isPresented: $renameTopic) {
            TextField("Topic name", text: $topicNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard case .topic(let id) = place else { return }
                do { try store.renameTopic(id, name: topicNameDraft, nowUs: Time.nowUs()); model.reload(); wake() }
                catch { actionError = error.localizedDescription }
            }
        }
        .fullScreenCover(isPresented: $deleteTopic) {
            if case .topic(let id) = place {
                TopicDeletionView(store: store, topic: TopicPlace(id: id, name: model.topicName ?? title, count: model.items.count), wake: wake)
            }
        }
        .toolbar {
            if let searchPlace {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.search(searchPlace)) { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search")
                }
            }
            if case .topic(let id) = place, model.topicName != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename", systemImage: "pencil") { topicNameDraft = model.topicName ?? title; renameTopic = true }
                        Button(model.topicUnavailable ? "Unarchive" : "Archive", systemImage: "archivebox") {
                            do { try store.setTopicArchived(id, archived: !model.topicUnavailable, nowUs: Time.nowUs()); model.reload(); wake() }
                            catch { actionError = error.localizedDescription }
                        }
                        Button("Delete Topic…", systemImage: "trash", role: .destructive) { deleteTopic = true }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Topic actions")
                }
            }
            ToolbarItem(placement: .principal) {
                let header = VStack(spacing: 0) {
                    Text(model.topicName ?? title).font(.plex(.sansSemibold, 17, relativeTo: .headline)).foregroundStyle(palette.ink)
                    SyncStatusLine(status: status)
                }
                if status.needsSettings {
                    Button(action: openSettings) { header.frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain)
                } else {
                    header
                }
            }
        }
    }
}
