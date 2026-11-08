import NoteBankKit
import SwiftUI

struct HomeComposerView: View {
    @Bindable var model: ComposerModel
    let store: Store
    let topics: [TopicPlace]
    let wake: () -> Void
    let notices: NoticeCenter
    @AppStorage("tunnelSwitch", store: Theme.store) private var tunnelOn = false
    @State private var focusRequest = 0
    @State private var handledRequest: UUID?
    @State private var naming = false
    @State private var awaitedTopic: String?
    private let requests = ComposeRequests.shared
    @Environment(\.palette) private var palette

    private var chip: Destination {
        get { model.homeTopicID.map(Destination.topic) ?? .inbox }
        nonmutating set {
            model.homeTopicID = if case .topic(let id) = newValue { id } else { nil }
            sync()
        }
    }

    private var chipTitle: String {
        if case .topic(let id) = chip, let topic = topics.first(where: { $0.id == id }) { return topic.name }
        return "Inbox"
    }

    private func sync() {
        model.destination = chip
        model.dropMissingTopic(open: topics)
        model.homeTopicID = if case .topic(let id) = model.destination { id } else { nil }
        if tunnelOn { model.destination = .tunnel }
    }

    private func use(newTopic id: String) {
        if topics.contains(where: { $0.id == id }) { chip = .topic(id) } else { awaitedTopic = id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerInput(text: $model.text, placeholder: tunnelOn ? "Send to your other devices…" : "Capture something…", minimumLines: 4, lineSpacing: 3, focusRequest: focusRequest) { provider, type in
                model.importPaste(provider, type: type)
            }
            .padding(.trailing, model.canClear ? 44 : 0)
            StagedAttachmentsView(model: model)
            HStack(spacing: 8) {
                Toggle("Tunnel", isOn: $tunnelOn)
                    .labelsHidden()
                    .tint(palette.accent)
                    .frame(minHeight: 44)
                Text("Tunnel")
                    .font(.plex(.sansMedium, 14, relativeTo: .callout))
                    .fixedSize()
                    .foregroundStyle(palette.ink)
                    .accessibilityHidden(true)
                if !tunnelOn {
                    Menu {
                        Button("New Topic…", systemImage: "plus") { naming = true }
                        Divider()
                        Button("Inbox") { chip = .inbox }
                        ForEach(topics) { topic in
                            Button(topic.name) { chip = .topic(topic.id) }
                        }
                    } label: {
                        PlaceChipLabel(title: chipTitle)
                    }
                    .accessibilityLabel("Destination")
                    .accessibilityValue(chipTitle)
                } else {
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    AttachmentPicker(model: model)
                    Button {
                        sync()
                        _ = model.send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(model.canSend ? palette.onAccent : palette.lineStrong)
                            .frame(width: 40, height: 40)
                            .background(model.canSend ? palette.accent : palette.chip, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!model.canSend)
                    .accessibilityLabel("Send")
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.plex(.sansMedium, 13, relativeTo: .footnote))
                    .foregroundStyle(palette.danger)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(tunnelOn ? palette.accentSoft : palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tunnelOn ? palette.accent : palette.line))
        .overlay(alignment: .topTrailing) {
            if model.canClear {
                Button {
                    model.clear()
                    notices.postCleared(.home)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.inkMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .onAppear(perform: sync)
        .onChange(of: tunnelOn) { sync() }
        .onChange(of: topics) {
            if let id = awaitedTopic, topics.contains(where: { $0.id == id }) {
                awaitedTopic = nil
                chip = .topic(id)
            }
            sync()
        }
        .newTopicDialog(isPresented: $naming) { name in
            try? store.pickerTopicProblem(named: name)
        } create: { name in
            use(newTopic: try store.pickerTopic(named: name, nowUs: Time.nowUs()))
            wake()
        }
        .onChange(of: requests.latest, initial: true) { _, request in
            guard let request, request.id != handledRequest else { return }
            handledRequest = request.id
            switch request.place {
            case .tunnel: tunnelOn = true
            case .topic(let id):
                tunnelOn = false
                chip = .topic(id)
            case .inbox:
                tunnelOn = false
                chip = .inbox
            }
            sync()
            focusRequest += 1
        }
    }
}
