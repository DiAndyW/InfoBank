import NoteBankKit
import SwiftUI

private enum DayEnd: Identifiable {
    case from, to
    var id: Self { self }
}

struct SearchView: View {
    let topics: [TopicPlace]
    let archived: [TopicPlace]
    let onOpen: (String) -> Void
    let onCancel: () -> Void
    @State private var model: SearchModel
    @State private var picking: DayEnd?
    @State private var draft = Date()
    @State private var fieldFocused = false
    @Environment(\.palette) private var palette

    init(store: Store, place: SearchPlace, topics: [TopicPlace], archived: [TopicPlace], onOpen: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _model = State(wrappedValue: SearchModel(store: store, place: place))
        self.topics = topics
        self.archived = archived
        self.onOpen = onOpen
        self.onCancel = onCancel
    }

    private var placeTitle: String {
        switch model.place {
        case .all: "Anywhere"
        case .inbox: "Inbox"
        case .tunnel: "Tunnel"
        case .topic(let id): (topics + archived).first { $0.id == id }?.name ?? "Anywhere"
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
                Button("Cancel", action: onCancel)
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
                            if !archived.isEmpty {
                                Section("Archived") {
                                    ForEach(archived) { Text($0.name).tag(SearchPlace.topic($0.id)) }
                                }
                            }
                        }
                    } label: { chip(placeTitle, trailing: "chevron.down", active: model.place != .all) }
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
                            SearchResultRow(result: result) { onOpen(result.id) }
                                .onAppear { if result.id == model.results.last?.id { model.loadMore() } }
                        }
                    }
                    .card()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private final class FocusingField: UITextField {
    private var focusedOnce = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !focusedOnce else { return }
        focusedOnce = true
        becomeFirstResponder()
    }
}

private struct SearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = FocusingField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.adjustsFontForContentSizeCategory = true
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: PlexFont.sans.rawValue, size: 17) ?? .systemFont(ofSize: 17))
        field.accessibilityLabel = "Search"
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Setting text mid-composition would cancel the IME's marked text.
        if field.markedTextRange == nil && field.text != text { field.text = text }
        if focused && !field.isFirstResponder && field.window != nil { field.becomeFirstResponder() }
        let ink = UIColor(palette.ink)
        if field.textColor != ink {
            field.textColor = ink
            field.tintColor = UIColor(palette.accent)
            field.attributedPlaceholder = NSAttributedString(string: "Search", attributes: [.foregroundColor: UIColor(palette.inkMuted), .font: field.font as Any])
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            if field.markedTextRange == nil { parent.text = field.text ?? "" }
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.focused { parent.focused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.focused { parent.focused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
        }
    }
}
