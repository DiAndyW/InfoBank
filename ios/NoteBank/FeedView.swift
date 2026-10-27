import NoteBankKit
import SwiftUI

struct ShowTarget: Equatable {
    let place: Place
    let itemID: String
}

struct FeedView: View {
    let place: Place
    let status: SyncStatus
    let openSettings: () -> Void
    let notices: NoticeCenter
    let onShow: (String) -> Void
    let foregrounds: Int
    @Binding var target: ShowTarget?

    @Environment(\.palette) private var palette
    @State private var model: FeedModel
    @State private var composer: ComposerModel
    @State private var highlighted: String?
    @State private var scrollsToNewest = false
    @State private var title: String

    init(
        place: Place, topicName: String?, services: Services, status: SyncStatus, openSettings: @escaping () -> Void,
        onShow: @escaping (String) -> Void, foregrounds: Int, target: Binding<ShowTarget?>
    ) {
        self.place = place
        self.status = status
        self.openSettings = openSettings
        self.notices = services.notices
        self.onShow = onShow
        self.foregrounds = foregrounds
        _target = target
        let title = switch place {
        case .all: "All Items"
        case .inbox: "Inbox"
        case .topic: topicName ?? ""
        }
        _title = State(wrappedValue: title)
        _model = State(wrappedValue: FeedModel(store: services.store, place: place))
        _composer = State(wrappedValue: ComposerModel(store: services.store, place: place, topicName: topicName) { [engine = services.engine] in
            Task { await engine.wake() }
        })
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
                            ItemRow(item: item, showsTopic: place == .all, highlighted: highlighted == item.id) {
                                model.discard(item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
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
                    NoticeView(message: notice.message, onShow: { onShow(notice.itemID) }, onDismiss: notices.dismiss)
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
