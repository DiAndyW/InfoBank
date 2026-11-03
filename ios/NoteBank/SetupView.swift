import NoteBankKit
import SwiftUI

struct SetupView: View {
    let model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up NoteBank")
                .font(.plex(.sansSemibold, 32, relativeTo: .largeTitle))
                .kerning(-0.32)
                .foregroundStyle(palette.ink)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text("Connect this iPhone to your Server. You can change this later in Settings.")
                .font(.plex(.sans, 15, relativeTo: .subheadline))
                .foregroundStyle(palette.inkMuted)
                .padding(.top, 6)
                .padding(.bottom, 24)
            ServerFields(model: model)
            Text("The secret stays in this iPhone's Keychain and is sent only to this Server.")
                .font(.plex(.sans, 13, relativeTo: .footnote))
                .foregroundStyle(palette.inkMuted)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            Spacer()
            Button {
                Task { _ = await model.save() }
            } label: {
                Text(model.saving ? "Saving…" : "Save")
                    .font(.plex(.sansSemibold, 17))
                    .foregroundStyle(model.canSave ? palette.onAccent : palette.lineStrong)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(model.canSave ? palette.accent : palette.chip, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!model.canSave)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(palette.surfaceSidebar)
        .discardAlert(model)
    }
}
