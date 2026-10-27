import NoteBankKit
import SwiftUI

struct ShowTarget: Equatable {
    let place: Place
    let itemID: String
}

struct FeedView: View {
    private let store: Store
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
    @State private var scrollsToNewest = false
    @State private var title: String
    @State private var copiedID: String?
    @State private var copies = 0
    @State private var commands: FeedItem?
    @State private var copyAfterSheet: FeedItem?
    @State private var actionError: String?
    @State private var asking: FeedItem?

    init(
        place: Place, topicName: String?, services: Services, status: SyncStatus, openSettings: @escaping () -> Void,
        onShow: @escaping (String) -> Void, foregrounds: Int, target: Binding<ShowTarget?>
    ) {
        self.store = services.store
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
        case .inbox: "Inbox"
        case .tunnel: "Tunnel"
        case .topic: topicName ?? ""
        }
        _title = State(wrappedValue: title)
        _model = State(wrappedValue: FeedModel(store: services.store, place: place))
        let destination: Destination = switch place {
        case .all, .inbox: .inbox
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

    private func copy(_ item: FeedItem) {
        guard let text = item.text else { return }
        UIPasteboard.general.string = text
        copies += 1
        let outcome = model.copied(item)
        if outcome == .trashed {
            copiedID = nil
            notices.postTrashed(itemID: item.id)
        } else {
            copiedID = item.id
        }
        if outcome == .ask { asking = item }
        wake()
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
                    if model.hasOlder {
                        ProgressView().frame(maxWidth: .infinity).onScrollVisibilityChange { visible in
                            if visible { model.loadOlder() }
                        }
                    }
                    if let error = model.loadError {
                        Text(error).font(.plex(.sansMedium, 13, relativeTo: .footnote)).foregroundStyle(palette.danger)
                    }
                    ForEach(days, id: \.start) { day in
                        HStack(spacing: 10) {
                            Rectangle().fill(palette.line).frame(height: 1)
                            Text(Calendar.current.isDateInToday(day.start) ? "Today" : day.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                                .font(.plex(.sansSemibold, 12, relativeTo: .caption))
                                .foregroundStyle(palette.inkMuted)
                            Rectangle().fill(palette.line).frame(height: 1)
                        }
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                        .accessibilityHidden(true)
                        ForEach(day.items) { item in
                            ItemRow(
                                item: item, showsTopic: place == .all, highlighted: highlighted == item.id,
                                copyable: place == .tunnel, copied: copiedID == item.id,
                                onCopy: { copy(item) }, onCommands: { commands = item })
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.items.map(\.id))
            .defaultScrollAnchor(.bottom)
            .background(palette.surface)
            .onChange(of: model.items.last?.id) { _, newest in
                guard scrollsToNewest, let newest else { return }
                scrollsToNewest = false
                withAnimation { proxy.scrollTo(newest, anchor: .bottom) }
            }
            .onChange(of: foregrounds) { model.reload() }
            .onChange(of: target, initial: true) { _, shown in
                guard let shown, shown.place == place else { return }
                target = nil
                guard model.items.contains(where: { $0.id == shown.itemID }) else { return }
                highlighted = shown.itemID
                withAnimation { proxy.scrollTo(shown.itemID, anchor: .center) } completion: {
                    withAnimation(.easeOut(duration: 1.5)) { highlighted = nil }
                }
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
                                }
                                model.reload()
                                notices.dismiss()
                                wake()
                            } catch { actionError = error.localizedDescription }
                        },
                        onDismiss: notices.dismiss)
                        .id(notice.id)
                }
                ComposerView(model: composer) {
                    scrollsToNewest = true
                    model.reload()
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
            ItemActionsView(item: item, store: store, onCopy: {
                copyAfterSheet = item
                commands = nil
            }, onChanged: { trashed, moved in
                model.reload()
                if trashed { notices.postTrashed(itemID: item.id, copied: false) }
                if moved { notices.postMoved(itemID: item.id, from: item.destination) }
                wake()
            })
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
            if let notice = notices.current, notice.action != .show { notices.dismiss() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                let header = VStack(spacing: 0) {
                    Text(title).font(.plex(.sansSemibold, 17, relativeTo: .headline)).foregroundStyle(palette.ink)
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
