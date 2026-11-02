import NoteBankKit
import SwiftUI

struct ServerFields: View {
    @Bindable var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server URL").font(.plex(.sansMedium, 13, relativeTo: .footnote)).foregroundStyle(palette.inkMuted)
                    TextField("", text: $model.url)
                        .accessibilityLabel("Server URL")
                        .font(.plex(.mono, 16))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(palette.line)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shared secret").font(.plex(.sansMedium, 13, relativeTo: .footnote)).foregroundStyle(palette.inkMuted)
                    SecureField(
                        "", text: $model.secret,
                        prompt: Text(model.hasSecret ? "Saved · type to replace" : "Paste or type the secret").foregroundStyle(palette.inkMuted)
                    )
                    .accessibilityLabel("Shared secret")
                    .font(.plex(.sans, 17))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(palette.ink)
            .card()
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.plex(.sansMedium, 13, relativeTo: .footnote))
                    .foregroundStyle(palette.danger)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}

struct SettingsView: View {
    @Binding var theme: Theme
    @State private var model: SettingsModel
    @State private var saved = false
    @State private var openedTheme: Theme
    private let wake: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    init(services: Services, theme: Binding<Theme>) {
        _theme = theme
        _openedTheme = State(initialValue: theme.wrappedValue)
        _model = State(wrappedValue: services.settingsModel())
        wake = services.wake
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .textCase(.uppercase)
            .kerning(0.96)
            .font(.plex(.sansSemibold, 12, relativeTo: .caption))
            .foregroundStyle(palette.inkMuted)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header("Server").padding(.top, 12)
                    ServerFields(model: model)
                    header("Tunnel")
                    Toggle(
                        "Trash Tunnel notes after copying",
                        isOn: Binding(
                            get: { model.trashAfterCopy },
                            set: { on in
                                if model.setTrashAfterCopy(on) { wake() }
                            })
                    )
                    .font(.plex(.sans, 17))
                    .foregroundStyle(palette.ink)
                    .tint(palette.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .card()
                    if let tunnelError = model.trashError {
                        Label(tunnelError, systemImage: "exclamationmark.triangle")
                            .font(.plex(.sansMedium, 13, relativeTo: .footnote))
                            .foregroundStyle(palette.danger)
                            .padding(.horizontal, 16)
                    }
                    header("Theme")
                    VStack(spacing: 0) {
                        ForEach(Theme.allCases, id: \.self) { option in
                            if option != Theme.allCases.first { Divider().overlay(palette.line) }
                            Button { theme = option } label: {
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(option.palette.surface)
                                        .strokeBorder(palette.lineStrong)
                                        .frame(width: 18, height: 18)
                                    Text(option.title).font(.plex(.sans, 17)).foregroundStyle(palette.ink)
                                    Spacer()
                                    if option == theme {
                                        Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.accent)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(option == theme ? .isSelected : [])
                        }
                    }
                    .card()
                }
                .padding(.horizontal, 16)
            }
            .background(palette.surfaceSidebar)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.saving ? "Saving…" : "Save") {
                        Task {
                            if await model.save() {
                                saved = true
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
        .onDisappear { if !saved { theme = openedTheme } }
    }
}
