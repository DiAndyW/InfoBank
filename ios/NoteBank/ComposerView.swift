import NoteBankKit
import SwiftUI

struct ComposerView: View {
    @Bindable var model: ComposerModel
    let title: String
    let onClear: () -> Void
    let onSent: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BarHeader(title: title) {
                Button("Clear draft") {
                    withTransaction(\.disablesAnimations, true) { if model.clear() { onClear() } }
                }
                .disabled(!model.canClear)
            }
            StagedAttachmentsView(model: model)
            HStack(alignment: .bottom, spacing: 4) {
                AttachmentPicker(model: model)
                ComposerInput(text: $model.text, placeholder: model.placeholder) { provider, type in
                    model.importPaste(provider, type: type)
                }
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
        .geometryGroup()
    }
}

struct BarHeader<Actions: View>: View {
    let title: String
    var emphasized = false
    @ViewBuilder let actions: () -> Actions
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(emphasized ? palette.ink : palette.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 8)
            actions().buttonStyle(QuietBarButton())
        }
        .font(.plex(.sansMedium, 13, relativeTo: .footnote))
        .padding(.leading, 4)
    }
}

private struct QuietBarButton: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? palette.ink : palette.lineStrong)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(configuration.isPressed ? palette.hover : palette.chip, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
