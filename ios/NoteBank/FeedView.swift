import NoteBankKit
import SwiftUI

enum FeedPlace: Hashable {
    case inbox, tunnel, trash, topic(String)

    var query: Place {
        switch self {
        case .inbox: .inbox
        case .tunnel: .tunnel
        case .trash: .trash
        case .topic(let id): .topic(id)
        }
    }
}

struct ShowTarget: Equatable {
    let place: FeedPlace
    let itemID: String
}

struct FeedView: View {
    private let store: Store
    private let transfers: AttachmentTransfers
    let place: FeedPlace
    let status: SyncStatus
    let openSettings: () -> Void
    let notices: NoticeCenter
    let onShow: (String) -> Void
    let onSearch: () -> Void
    let foregrounds: Int
    let wake: () -> Void
    @Binding var target: ShowTarget?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 26
    @State private var model: FeedModel
    private let composers: Composers
    let onUndoClear: (DraftPlace) -> Void
    @State private var highlighted: String?
    @State private var visible = false
    @State private var scrollsToNewest = false
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollGeometry: ScrollGeometry?
    @State private var beforePrepend: ScrollGeometry?
    @State private var prependOffset: CGFloat?
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var olderVisible = false
    @State private var pendingReveal: String?
    @State private var title: String
    @State private var copiedID: String?
    @State private var copyTask: Task<Void, Never>?
    @State private var copies = 0
    @State private var commands: FeedItem?
    @State private var panel: ItemPanelPresentation?
    @State private var expandedActions = false
    @Environment(\.dismiss) private var dismiss
    let editorNavigation: EditorNavigation
    @State private var editing: (item: FeedItem, model: ItemEditorModel)?
    @State private var actionError: String?
    @State private var asking: FeedItem?
    @State private var renameTopic = false
    @State private var topicNameDraft = ""
    @State private var deleteTopic = false
    @State private var deletingEmpty: TopicPlace?
    @State private var batch: BatchItemActions

    init(
        place: FeedPlace, topicName: String?, services: Services, composers: Composers, onUndoClear: @escaping (DraftPlace) -> Void, status: SyncStatus, openSettings: @escaping () -> Void,
        onShow: @escaping (String) -> Void, onSearch: @escaping () -> Void, foregrounds: Int, target: Binding<ShowTarget?>, editorNavigation: EditorNavigation
    ) {
        self.editorNavigation = editorNavigation
        self.composers = composers
        self.onUndoClear = onUndoClear
        self.store = services.store
        self.transfers = services.transfers
        self.place = place
        self.status = status
        self.openSettings = openSettings
        self.notices = services.notices
        self.onShow = onShow
        self.onSearch = onSearch
        self.foregrounds = foregrounds
        wake = services.wake
        _target = target
        _batch = State(wrappedValue: BatchItemActions(services: services))
        let title = switch place {
        case .trash: "Trash"
        case .inbox: "Inbox"
        case .tunnel: "Tunnel"
        case .topic: topicName ?? ""
        }
        _title = State(wrappedValue: title)
        _model = State(wrappedValue: FeedModel(store: services.store, place: place.query))
    }

    private var draftPlace: DraftPlace? {
        switch place {
        case .inbox: .inbox
        case .tunnel: .tunnel
        case .topic(let id): .topic(id)
        case .trash: nil
        }
    }

    private var composer: ComposerModel? {
        guard let draftPlace, !model.topicUnavailable else { return nil }
        let destination: Destination = switch place {
        case .inbox, .trash: .inbox
        case .tunnel: .tunnel
        case .topic(let id): .topic(id)
        }
        let placeholder = switch place {
        case .tunnel: "Send to your other devices…"
        case .topic: "Capture to \(model.topicName ?? title)"
        default: "Capture to the Inbox"
        }
        return composers.model(for: draftPlace, destination: destination, placeholder: placeholder)
    }

    private func requestLeave(_ action: @escaping () -> Void) {
        guard commands == nil else { return }
        editorNavigation.requestLeave(action)
    }

    private func openActions(_ item: FeedItem) {
        guard panel == nil else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        expandedActions = false
        actionError = nil
        panel = ItemPanelPresentation()
        commands = item
    }

    private func closePanel(then action: @escaping () -> Void = {}) {
        guard let current = panel else { action(); return }
        current.dismiss {
            guard panel?.id == current.id else { return }
            actionError = nil
            commands = nil
            panel = nil
            action()
        }
    }

    @ViewBuilder private var panelContent: some View {
        if let item = commands {
            if place == .trash {
                NavigationStack {
                    List {
                        if let actionError { Text(actionError).foregroundStyle(palette.danger) }
                        Button("Restore", systemImage: "arrow.uturn.backward") {
                            do {
                                try store.restore(itemID: item.id, nowUs: Time.nowUs())
                                try notices.postRestored(itemID: item.id, store: store)
                                model.reload()
                                wake()
                                closePanel()
                            } catch { actionError = errorMessage(error) }
                        }.themedSheetRow()
                    }.themedSheetList()
                    .navigationTitle("Item actions")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { closePanel() } } }
                }.themedSheet()
            } else {
                ItemActionsView(item: item, store: store, place: place.query, trashAfterCopy: model.trashAfterCopy, onCopy: { choice in
                    switch choice {
                    case .item:
                        let panelID = panel?.id
                        copy(item, choice: choice, onCopied: {
                            guard panel?.id == panelID, commands?.id == item.id else { return }
                            closePanel()
                        })
                    case .text:
                        if let text = item.text { UIPasteboard.general.string = text; notices.postCopiedText() }
                        closePanel()
                    }
                }, onEdit: { text in
                    guard panel?.closing == false else { return }
                    closePanel {
                        requestLeave {
                            let editor = ItemEditorModel(store: store, item: item, text: text)
                            withAnimation(reduceMotion ? nil : .smooth) { editing = (item, editor) }
                            editorNavigation.begin(editor) { completion in
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                withAnimation(reduceMotion ? nil : .smooth) { editing = nil } completion: { completion() }
                            }
                        }
                    }
                }, onChanged: { trashed, moved in
                    model.reload()
                    if trashed { notices.postTrashed(itemID: item.id, copied: false) }
                    if moved {
                        do { try notices.postMoved(itemID: item.id, from: item.destination, store: store) }
                        catch { actionError = errorMessage(error) }
                    }
                    wake()
                }, onDismiss: { closePanel() }, expanded: $expandedActions, actionError: $actionError)
            }
        }
    }

    private func revealTarget(_ proxy: ScrollViewProxy) {
        // A covered Feed of the same Place must not take the target from the one on top.
        guard visible, let shown = target, shown.place == place else { return }
        target = nil
        olderVisible = false
        beforePrepend = nil
        prependOffset = nil
        if model.reveal(shown.itemID) { pendingReveal = shown.itemID }
    }

    private func correctPrepend() {
        guard let before = beforePrepend, let geometry = scrollGeometry,
              prependOffset == nil, !scrollPhase.isScrolling,
              geometry.contentSize.height != before.contentSize.height else { return }
        let offset = before.contentOffset.y + before.contentInsets.top + geometry.contentSize.height - before.contentSize.height
        prependOffset = offset
        Task { @MainActor in
            await Task.yield()
            guard visible, prependOffset == offset else { return }
            scrollPosition.scrollTo(y: offset)
        }
    }

    private func loadOlderIfReady() {
        guard model.hasOlder, olderVisible, visible, !scrollPhase.isScrolling, beforePrepend == nil, prependOffset == nil else { return }
        let count = model.items.count
        beforePrepend = place == .trash ? nil : scrollGeometry
        var transaction = Transaction()
        transaction.disablesAnimations = place != .trash
        withTransaction(transaction) { model.loadOlder() }
        if model.items.count == count { beforePrepend = nil }
    }

    private var loadMore: some View {
        ProgressView().frame(maxWidth: .infinity).ruledLines().onScrollVisibilityChange { shown in
            olderVisible = shown
            loadOlderIfReady()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        FeedSectionHeader(title: title).ruledLines()
    }

    private func itemRow(_ item: FeedItem, showsTime: Bool = true) -> some View {
        SelectableItemRow(selection: batch.selection, item: item, busy: batch.busy,
                          onCommands: { openActions(item) }) {
            ItemRow(item: item, showsTopic: place == .trash, highlighted: highlighted == item.id || editing?.item.id == item.id,
                    copyable: CopyActions(place: place.query, hasText: item.text != nil).row, copied: copiedID == item.id,
                    onCopy: { copy(item) }, onCommands: { openActions(item) }, inTrash: place == .trash, showsTime: showsTime)
        }
        .ruledLines()
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    private func copy(_ item: FeedItem, choice: ItemActionsView.Copy? = nil, onCopied: (() -> Void)? = nil) {
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
                let outcome: CopyOutcome
                if case .item(let preference) = choice { outcome = model.copied(item, preference: preference) }
                else { outcome = model.copied(item) }
                if outcome == .trashed {
                    copiedID = nil
                    notices.postTrashed(itemID: item.id)
                } else { copiedID = item.id }
                onCopied?()
                if outcome == .ask { asking = item }
                wake()
            } catch is CancellationError {
            } catch { actionError = errorMessage(error) }
        }
    }

    private func answer(_ on: Bool, _ item: FeedItem) {
        let saved = model.answerTrashAfterCopy(on, item: item)
        if saved && on { notices.postTrashed(itemID: item.id) }
        wake()
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.hasOlder && place != .trash { loadMore }
                        if let error = model.loadError {
                            Text(error).font(.plex(.sansMedium, 13, relativeTo: .footnote)).foregroundStyle(palette.danger)
                                .ruledTextSpacing(.sansMedium, 13, relativeTo: .footnote)
                                .frame(maxWidth: palette.rule == nil ? nil : .infinity, alignment: .leading).ruledLines()
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
                            ForEach(FeedDay.group(model.items)) { day in
                                sectionHeader(Calendar.current.isDateInToday(day.start) ? "Today" : day.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                                ForEach(day.rows) { row in itemRow(row.item, showsTime: row.showsTime) }
                            }
                        }
                        if model.hasOlder && place == .trash { loadMore }
                        if model.items.isEmpty && model.loadError == nil {
                            Text(place == .trash ? "Trash is empty" : "No Items yet")
                                .font(.plex(.sans, 15)).foregroundStyle(palette.inkMuted)
                                .ruledTextSpacing(.sans, 15, relativeTo: .body)
                                .frame(maxWidth: .infinity).padding(.vertical, palette.rule == nil ? 32 : 0).ruledLines()
                        }
                    }
                    .frame(maxWidth: palette.rule == nil ? nil : .infinity, alignment: .leading)
                    .background {
                        if palette.rule != nil {
                            GeometryReader { content in
                                RuledPaper()
                                    .frame(height: max(0, viewport.size.height - 4 - content.size.height))
                                    .offset(y: content.size.height)
                            }
                        }
                    }
                    .frame(minHeight: palette.rule == nil ? nil : max(0, viewport.size.height - 4), alignment: .topLeading)
                    .environment(\.ruledLine, palette.rule == nil ? nil : lineHeight)
                    .padding(.horizontal, feedHorizontalGutter)
                    .padding(.bottom, palette.rule == nil ? 8 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let bar = palette.feedBar { bar.frame(height: 4) }
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                .highPriorityGesture(TapGesture().onEnded { requestLeave {} }, including: editing == nil ? .subviews : .all)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.items.map(\.id))
                .defaultScrollAnchor(place == .trash ? .top : .bottom, for: .initialOffset)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                    scrollGeometry = geometry
                    if let offset = prependOffset, abs(geometry.contentOffset.y + geometry.contentInsets.top - offset) < 1 {
                        beforePrepend = nil
                        prependOffset = nil
                    } else {
                        correctPrepend()
                    }
                }
                .onScrollPhaseChange { _, phase in
                    scrollPhase = phase
                    correctPrepend()
                    loadOlderIfReady()
                }
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
                    // A scroll sent before the Feed's first layout is dropped, so wait for that layout.
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation { proxy.scrollTo(id, anchor: .center) } completion: {
                            withAnimation(.easeOut(duration: 1.5)) { highlighted = nil }
                        }
                    }
                }
                .onChange(of: foregrounds) { model.reload() }
                .onChange(of: target, initial: true) { revealTarget(proxy) }
                .onAppear {
                    visible = true
                    revealTarget(proxy)
                }
            }
        }
        .overlay(alignment: .bottom) {
            ItemNoticeView(notices: notices, store: store, wake: wake, onShow: { id in requestLeave { onShow(id) } }, onError: { actionError = $0 }, onUndoClear: onUndoClear)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let (item, editor) = editing {
                ItemEditorView(model: editor, navigation: editorNavigation, actionError: $actionError, onSaved: { outcome in
                    model.reload()
                    if outcome == .trashed { notices.postTrashed(itemID: item.id, copied: false) }
                    wake()
                    editorNavigation.end()
                }, onCancel: { requestLeave {} })
                .id(ObjectIdentifier(editor))
                .bottomBar(palette)
                .transition(.move(edge: .bottom))
            } else if batch.selection.isSelecting {
                BatchActionsBar(batch: batch, items: model.items, trash: place == .trash, tunnel: place == .tunnel, trashAfterCopy: model.trashAfterCopy)
            } else {
                VStack(spacing: 8) {
                    if let composer, let draftPlace {
                        ComposerView(model: composer, title: model.topicName ?? title, onClear: { notices.postCleared(draftPlace) }) {
                            scrollsToNewest = true
                            model.reload()
                        }
                    }
                }
                .bottomBar(palette)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.35)), removal: .identity))
            }
        }
        .modifier(ItemPanel(presentation: panel, expanded: expandedActions, onDismissed: { closePanel() }) {
            panelContent
        })
        .onChange(of: model.items) { _, items in batch.reconcile(items) }
        .onChange(of: batch.error) { _, error in if let error { actionError = error; batch.error = nil } }
        .navigationBarBackButtonHidden(editing != nil)
        .background(EditorBackGestureGuard(active: editing != nil, blocked: editing != nil) {
            requestLeave { dismiss() }
        })
        .alert("Couldn't finish the action", isPresented: Binding(get: { actionError != nil && panel == nil && editing == nil }, set: { if !$0 { actionError = nil } })) {
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
            isPresented: Binding(get: { asking != nil && panel == nil }, set: { if !$0 { asking = nil } }),
            presenting: asking
        ) { item in
            Button("Turn on") { answer(true, item) }
            Button("Not now", role: .cancel) { answer(false, item) }
        }
        .onDisappear {
            visible = false
            beforePrepend = nil
            prependOffset = nil
            scrollPhase = .idle
            olderVisible = false
            copyTask?.cancel()
            batch.cancel()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .containerBackground(palette.surface, for: .navigation)
        .alert("Rename Topic", isPresented: $renameTopic) {
            TextField("Topic name", text: $topicNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard case .topic(let id) = place else { return }
                do { try store.renameTopic(id, name: topicNameDraft, nowUs: Time.nowUs()); model.reload(); wake() }
                catch { actionError = errorMessage(error) }
            }
        }
        .emptyTopicDeletionAlert(topic: $deletingEmpty, store: store, notices: notices, wake: wake, onError: { actionError = $0 })
        .fullScreenCover(isPresented: $deleteTopic) {
            if let topic = model.topicPlace {
                TopicDeletionView(store: store, topic: topic, notices: notices, wake: wake)
            }
        }
        .toolbar {
            if editing != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { requestLeave { dismiss() } } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("Back")
                }
            }
            if batch.selection.isSelecting {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { batch.cancel() } }
            } else {
                if place != .trash {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { requestLeave { onSearch() } } label: { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel("Search")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Select", systemImage: "checkmark.circle") {
                            requestLeave { copyTask?.cancel(); batch.selection.enter() }
                        }
                        .disabled(model.items.isEmpty)
                        if case .topic = place, model.topicName != nil {
                            Button("Rename", systemImage: "pencil") { requestLeave { topicNameDraft = model.topicName ?? title; renameTopic = true } }
                            Button("Delete Topic…", systemImage: "trash", role: .destructive) {
                                requestLeave {
                                    if model.topicCount == 0 {
                                        deletingEmpty = model.topicPlace
                                    } else { deleteTopic = true }
                                }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("More")
                }
            }
            ToolbarItem(placement: .principal) {
                let header = VStack(spacing: 0) {
                    Text(model.topicName ?? title).font(.plex(.sansSemibold, 17, relativeTo: .headline)).foregroundStyle(palette.ink)
                    SyncStatusLine(status: status)
                }
                if status.needsSettings {
                    Button { requestLeave(openSettings) } label: { header.frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain)
                } else {
                    header
                }
            }
        }
    }
}

private extension View {
    func bottomBar(_ palette: Palette) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}
