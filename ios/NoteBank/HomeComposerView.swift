import NoteBankKit
import SwiftUI

struct HomeComposerView: View {
    @Bindable var model: ComposerModel
    let topics: [TopicPlace]
    @AppStorage("tunnelSwitch", store: Theme.store) private var tunnelOn = false
    @State private var chip = Destination.inbox
    @Environment(\.palette) private var palette

    private var chipTitle: String {
        if case .topic(let id) = chip, let topic = topics.first(where: { $0.id == id }) { return "To \(topic.name)" }
        return "To Inbox"
    }

    private func sync() {
        model.destination = chip
        model.dropMissingTopic(open: topics)
        chip = model.destination
        if tunnelOn { model.destination = .tunnel }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerInput(text: $model.text, placeholder: tunnelOn ? "Send to your other devices…" : "Capture something…", minimumLines: 4, lineSpacing: 3) { provider, type in
                model.importPaste(provider, type: type)
            }
            StagedAttachmentsView(model: model)
            HStack(spacing: 8) {
                Toggle("Tunnel", isOn: $tunnelOn)
                    .labelsHidden()
                    .tint(palette.accent)
                    .frame(minHeight: 44)
                Text("Tunnel")
                    .font(.plex(.sansMedium, 14, relativeTo: .callout))
                    .foregroundStyle(palette.ink)
                    .accessibilityHidden(true)
                if !tunnelOn {
                    Menu {
                        Button("Inbox") { chip = .inbox }
                        ForEach(topics) { topic in
                            Button(topic.name) { chip = .topic(topic.id) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(chipTitle).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .font(.plex(.sansMedium, 14, relativeTo: .callout))
                        .foregroundStyle(palette.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(palette.chip, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Destination")
                    .accessibilityValue(chipTitle)
                }
                Spacer(minLength: 0)
                AttachmentPicker(model: model)
                Button {
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
        .onAppear(perform: sync)
        .onChange(of: tunnelOn) { sync() }
        .onChange(of: chip) { sync() }
        .onChange(of: topics) { sync() }
    }
}
