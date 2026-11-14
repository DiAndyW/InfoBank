import NoteBankKit
import SwiftUI

private enum DayEnd: Identifiable {
    case from, to
    var id: Self { self }
}

struct SearchView: View {
    let onUndoClear: (DraftPlace) -> Void
    let topics: [TopicPlace]
    let onOpen: (String) -> Void
    let onOpenTopic: (String) -> Void
    let onCancel: () -> Void
    private let store: Store
    private let notices: NoticeCenter
    private let wake: () -> Void
    @State private var batch: BatchItemActions
    @State private var model: SearchModel
    @State private var picking: DayEnd?
    @State private var draft = Date()
    @State private var fieldFocused = false
    @Environment(\.palette) private var palette

    init(services: Services, onUndoClear: @escaping (DraftPlace) -> Void, place: SearchPlace, topics: [TopicPlace], onOpen: @escaping (String) -> Void, onOpenTopic: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _model = State(wrappedValue: SearchModel(store: services.store, place: place))
        self.onUndoClear = onUndoClear
        store = services.store
        notices = services.notices
        wake = services.wake
        _batch = State(wrappedValue: BatchItemActions(services: services))
        self.topics = topics
        self.onOpen = onOpen
        self.onOpenTopic = onOpenTopic
        self.onCancel = onCancel
    }

    private var matchingTopics: [TopicPlace] { TopicPlace.matching(topics, text: model.text) }

    private func resultHeading(_ text: String) -> some View {
        Text(text).textCase(.uppercase).kerning(0.96)
            .font(.plex(.sansSemibold, 12, relativeTo: .caption)).foregroundStyle(palette.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var placeTitle: String {
        switch model.place {
        case .all: "Anywhere"
        case .inbox: "Inbox"
        case .tunnel: "Tunnel"
        case .topic(let id): topics.first { $0.id == id }?.name ?? "Anywhere"
        }
    }

    private func title(_ dates: SearchDates) -> String {
        switch dates {
        case .any: "Any time"
        case .pastWeek: "Past week"
        case .pastMonth: "Past month"
        case .pastYear: "Past year"
        case .custom: "Custom"
        }
    }

    private var dateChoice: Binding<SearchDates> {
        Binding {
            if case .custom = model.dates { .custom(from: nil, to: nil) } else { model.dates }
        } set: {
            if case .custom = $0, case .custom = model.dates { return }
            model.dates = $0
        }
    }

    private func chip(_ title: String, leading: String? = nil, trailing: String? = nil, active: Bool) -> some View {
        HStack(spacing: 6) {
            if let leading { Image(systemName: leading).font(.system(size: 13)) }
            Text(title).lineLimit(1)
            if let trailing { Image(systemName: trailing).font(.system(size: 11, weight: .semibold)) }
        }
        .chipStyle(active: active)
    }

    private func dayChip(_ title: String, _ day: Date?, _ end: DayEnd) -> some View {
        HStack(spacing: 0) {
            Button {
                draft = day ?? Date()
                picking = end
            } label: {
                chip("\(title) \(day?.formatted(date: .abbreviated, time: .omitted) ?? "Any")", active: day != nil)
            }
            if day != nil {
                Button {
                    guard case .custom(var from, var to) = model.dates else { return }
                    if end == .from { from = nil } else { to = nil }
                    model.dates = .custom(from: from, to: to)
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(palette.lineStrong).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear \(title)")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(palette.inkMuted).accessibilityHidden(true)
                    SearchField(text: $model.text, focused: $fieldFocused).frame(maxWidth: .infinity)
                    if !model.text.isEmpty {
                        Button { model.text = "" } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(palette.chip)
                                .frame(width: 28, height: 28)
                                .background(palette.lineStrong, in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.leading, 12)
                .frame(height: 40)
                .background(palette.chip, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { fieldFocused = true }
                Button(batch.selection.isSelecting ? "Done" : "Cancel", action: batch.selection.isSelecting ? batch.cancel : onCancel)
                    .font(.plex(.sans, 17))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Place", selection: $model.place) {
                            Text("Anywhere").tag(SearchPlace.all)
                            Text("Inbox").tag(SearchPlace.inbox)
                            Text("Tunnel").tag(SearchPlace.tunnel)
                            ForEach(topics) { Text($0.name).tag(SearchPlace.topic($0.id)) }
                        }
                    } label: { PlaceChipLabel(title: placeTitle, active: model.place != .all) }
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.3 }
                        .accessibilityLabel("Place")
                        .accessibilityValue(placeTitle)
                    Menu {
                        Picker("Date", selection: dateChoice) {
                            ForEach([SearchDates.any, .pastWeek, .pastMonth, .pastYear, .custom(from: nil, to: nil)], id: \.self) { Text(title($0)) }
                        }
                    } label: { chip(title(model.dates), trailing: "chevron.down", active: model.dates != .any) }
                        .accessibilityLabel("Date")
                        .accessibilityValue(title(model.dates))
                    Button { model.hasFiles.toggle() } label: { chip("Has files", leading: "paperclip", active: model.hasFiles) }
                        .accessibilityValue(model.hasFiles ? "On" : "Off")
                }
                .padding(.horizontal, 16)
            }
            if case .custom(let from, let to) = model.dates {
                HStack(spacing: 0) {
                    dayChip("From", from, .from)
                    dayChip("To", to, .to)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            }
            if let error = model.error {
                Text("Couldn't search. \(error)")
                    .font(.plex(.sansMedium, 13, relativeTo: .footnote))
                    .foregroundStyle(palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if !matchingTopics.isEmpty {
                        resultHeading("Topics")
                        VStack(spacing: 0) {
                            ForEach(matchingTopics) { topic in
                                if topic.id != matchingTopics.first?.id { Divider().overlay(palette.line) }
                                Button { onOpenTopic(topic.id) } label: {
                                    HStack(spacing: 8) {
                                        Text(topic.name).font(.plex(.sans, 17)).foregroundStyle(palette.ink)
                                        Spacer(minLength: 0)
                                        Text(String(topic.count)).font(.plex(.mono, 13)).foregroundStyle(palette.inkMuted)
                                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.lineStrong)
                                    }.padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.card().padding(.horizontal, 16)
                        resultHeading("Items")
                    }
                    if model.isEmptyResult {
                        VStack(spacing: 4) {
                            Text("No Items match.").font(.plex(.sans, 15)).foregroundStyle(palette.inkMuted)
                            if model.hasFilters {
                                Button("Clear filters") { model.clearFilters() }
                                    .font(.plex(.sansMedium, 15, relativeTo: .callout))
                                    .frame(minHeight: 44)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else if !model.results.isEmpty {
                        LazyVStack(spacing: 0) {
                            ForEach(model.results) { result in
                                if result.id != model.results.first?.id { Divider().overlay(palette.line) }
                                SelectableItemRow(selection: batch.selection, item: result.item, busy: batch.busy,
                                                  onBegin: { fieldFocused = false }) {
                                    SearchResultRow(result: result) { onOpen(result.id) }
                                }
                                    .onAppear { if result.id == model.results.last?.id { model.loadMore() } }
                            }
                        }
                        .card()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            ItemNoticeView(notices: notices, store: store, wake: wake, onShow: onOpen, onError: { batch.error = $0 }, onUndoClear: onUndoClear)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if batch.selection.isSelecting {
                BatchActionsBar(batch: batch, items: model.results.map(\.item))
            }
        }
        .onChange(of: model.text) { batch.cancel() }
        .onChange(of: model.place) { batch.cancel() }
        .onChange(of: model.dates) { batch.cancel() }
        .onChange(of: model.hasFiles) { batch.cancel() }
        .onChange(of: model.results) { _, results in batch.reconcile(results.map(\.item)) }
        .onDisappear { batch.cancel() }
        .alert("Couldn't finish the action", isPresented: Binding(get: { batch.error != nil }, set: { if !$0 { batch.error = nil } })) {
            Button("OK") { batch.error = nil }
        } message: { Text(batch.error ?? "") }
        .containerBackground(palette.surfaceSidebar, for: .navigation)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $picking) { end in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") {
                        guard case .custom(var from, var to) = model.dates else { return }
                        if end == .from { from = draft } else { to = draft }
                        model.dates = .custom(from: from, to: to)
                        picking = nil
                    }
                        .font(.plex(.sansMedium, 17))
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 16)
                DatePicker(end == .from ? "From" : "To", selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .background(palette.surface)
            .presentationDetents([.medium])
        }
    }
}
