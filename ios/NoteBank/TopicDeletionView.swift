import NoteBankKit
import SwiftUI

struct TopicDeletionView: View {
    let store: Store
    let topic: TopicPlace
    let notices: NoticeCenter
    let wake: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @ScaledMetric private var choiceIconWidth = 24
    @ScaledMetric private var searchFieldHeight = 40
    @State private var selecting = false
    @State private var model: TopicDeletionModel
    @State private var fieldFocused = false
    @State private var confirm = false
    @State private var keep: TopicKeep = .all
    @State private var confirmationMessage = ""
    @State private var error: String?

    init(store: Store, topic: TopicPlace, notices: NoticeCenter, wake: @escaping () -> Void) {
        self.store = store
        self.topic = topic
        self.notices = notices
        self.wake = wake
        _model = State(wrappedValue: TopicDeletionModel(store: store, topicID: topic.id))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let error { Text(error).foregroundStyle(palette.danger) }
                if selecting {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep \(model.kept.count) of \(model.total)")
                            .font(.plex(.sansSemibold, 17, relativeTo: .headline))
                            .accessibilityAddTraits(.isHeader)
                        Text("Choose what items to keep")
                            .font(.plex(.sans, 13, relativeTo: .footnote))
                            .foregroundStyle(palette.inkMuted)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(palette.inkMuted).accessibilityHidden(true)
                        SearchField(text: $model.text, focused: $fieldFocused, autofocus: false)
                            .frame(maxWidth: .infinity)
                        if !model.text.isEmpty {
                            Button { model.text = "" } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(palette.chip)
                                    .frame(width: 28, height: 28)
                                    .background(palette.lineStrong, in: Circle())
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Clear")
                        }
                    }
                    .padding(.leading, 12)
                    .frame(height: searchFieldHeight)
                    .background(palette.chip, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { fieldFocused = true }
                    if let error = model.error {
                        Text(error).font(.plex(.sans, 13, relativeTo: .footnote)).foregroundStyle(palette.danger)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.items.isEmpty && model.error == nil {
                                Text("No matching Items")
                                    .font(.plex(.sans, 15, relativeTo: .callout))
                                    .foregroundStyle(palette.inkMuted)
                                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                            }
                            ForEach(model.items) { item in
                                Button {
                                    if model.kept.contains(item.id) { model.kept.remove(item.id) }
                                    else { model.kept.insert(item.id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: model.kept.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 18))
                                            .foregroundStyle(model.kept.contains(item.id) ? palette.accent : palette.lineStrong)
                                        HStack(spacing: 4) {
                                            if item.text == nil { Image(systemName: "paperclip") }
                                            Text(item.text ?? item.attachmentNames.joined(separator: ", "))
                                                .lineLimit(2)
                                        }
                                        .font(.plex(.serif, 17))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(item.date.formatted(date: .omitted, time: .shortened))
                                            .font(.plex(.mono, 12, relativeTo: .caption))
                                            .foregroundStyle(palette.inkMuted)
                                            .fixedSize()
                                    }
                                    .padding(.vertical, 10)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(item.label + ", " + item.date.formatted(date: .abbreviated, time: .shortened))
                                .accessibilityValue(model.kept.contains(item.id) ? "Selected to keep" : "Not selected")
                                .accessibilityAddTraits(model.kept.contains(item.id) ? [.isSelected] : [])
                                Divider().overlay(palette.line)
                            }
                            if model.hasMore {
                                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .onAppear { model.loadMore() }
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    Button(role: .destructive) {
                        do {
                            confirmationMessage = try model.confirmationMessage()
                            keep = .only(model.kept)
                            fieldFocused = false
                            confirm = true
                        } catch { self.error = errorMessage(error) }
                    } label: {
                        Text("Delete Topic")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(palette.danger)
                    .foregroundStyle(palette.danger)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Delete “\(topic.name)”?").font(.plex(.sansSemibold, 17, relativeTo: .headline))
                            Text("It has \(topic.count) \(topic.count == 1 ? "Item" : "Items").")
                                .font(.plex(.sans, 17))
                                .foregroundStyle(palette.inkMuted)
                            VStack(spacing: 0) {
                                Button { keep = .all; confirm = true } label: {
                                    HStack {
                                        Image(systemName: "tray").frame(width: choiceIconWidth)
                                        Text("Keep all in Inbox")
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(palette.inkMuted)
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                Divider().overlay(palette.line)
                                Button { selecting = true } label: {
                                    HStack {
                                        Image(systemName: "checklist").frame(width: choiceIconWidth)
                                        Text("Select manually…")
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(palette.inkMuted)
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                Divider().overlay(palette.line)
                                Button(role: .destructive) { keep = .none; confirm = true } label: {
                                    HStack {
                                        Image(systemName: "trash").frame(width: choiceIconWidth)
                                        Text("Move all to Trash")
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(palette.inkMuted)
                                    }
                                    .foregroundStyle(palette.danger)
                                    .padding(16)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                            }
                            .font(.plex(.sans, 17))
                            .buttonStyle(.plain)
                            .card()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(palette.ink)
            .background(palette.surface)
            .tint(palette.accent)
            .toolbarBackground(palette.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(selecting ? "Keep Items" : "Delete Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Delete “\(topic.name)”?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Topic", role: .destructive) {
                    do {
                        let message = try store.deleteTopic(topic.id, keeping: keep, nowUs: Time.nowUs())
                        notices.postTopicDeleted(message)
                        wake()
                        dismiss()
                    }
                    catch { self.error = errorMessage(error) }
                }
            } message: {
                switch keep {
                case .all: Text("Its Items will move to Inbox.")
                case .none: Text("Its Items will move to Trash.")
                case .only: Text(confirmationMessage)
                }
            }
        }
    }
}

extension View {
    func emptyTopicDeletionAlert(
        topic: Binding<TopicPlace?>, store: Store, notices: NoticeCenter,
        wake: @escaping () -> Void, onError: @escaping (String) -> Void
    ) -> some View {
        alert(
            "Delete “\(topic.wrappedValue?.name ?? "")”?",
            isPresented: Binding(get: { topic.wrappedValue != nil }, set: { if !$0 { topic.wrappedValue = nil } }),
            presenting: topic.wrappedValue
        ) { topic in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                do {
                    let message = try store.deleteTopic(topic.id, keeping: .all, nowUs: Time.nowUs())
                    notices.postTopicDeleted(message)
                    wake()
                } catch { onError(errorMessage(error)) }
            }
        } message: { _ in
            Text("It has no Items, so nothing will be moved.")
        }
    }
}
