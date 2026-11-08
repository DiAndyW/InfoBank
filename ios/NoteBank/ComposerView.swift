import NoteBankKit
import SwiftUI

struct ComposerView: View {
    @Bindable var model: ComposerModel
    let onClear: () -> Void
    let onSent: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StagedAttachmentsView(model: model)
            HStack(alignment: .bottom, spacing: 4) {
                AttachmentPicker(model: model)
                ComposerInput(text: $model.text, placeholder: model.placeholder) { provider, type in
                    model.importPaste(provider, type: type)
                }
                    .padding(.trailing, model.canClear ? 44 : 0)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.line))
                    .overlay(alignment: .topTrailing) {
                        if model.canClear {
                            Button {
                                model.clear()
                                onClear()
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
