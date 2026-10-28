import NoteBankKit
import SwiftUI

struct ComposerView: View {
    @Bindable var model: ComposerModel
    let onSent: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StagedAttachmentsView(model: model)
            HStack(alignment: .bottom, spacing: 4) {
                AttachmentPicker(model: model)
                TextField("", text: $model.text, prompt: Text(model.placeholder).foregroundStyle(palette.inkMuted), axis: .vertical)
                    .lineLimit(1...6)
                    .font(.plex(.serif, 17))
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.line))
                Button {
                    if model.send() { onSent() }
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
                    .padding(.horizontal, 14)
            }
        }
    }
}
