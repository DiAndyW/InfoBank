import NoteBankKit
import SwiftUI
import UIKit

struct ItemEditorView: View {
    @Bindable var model: ItemEditorModel
    @Bindable var navigation: EditorNavigation
    @Binding var actionError: String?
    let onSaved: (EditOutcome) -> Void
    let onCancel: () -> Void
    @Environment(\.palette) private var palette
    @State private var focusRequest = 0
    @State private var confirmingTrash = false

    var body: some View {
        let confirmingLeave = navigation.confirmingLeave
        VStack(alignment: .leading, spacing: 4) {
            BarHeader(title: "Editing", emphasized: true) {
                Button(ItemEditorModel.clearLabel) {
                    withTransaction(\.disablesAnimations, true) { model.clear() }
                }
                .disabled(model.isEmpty || !model.canSave)
                Button(ItemEditorModel.cancel) { onCancel() }.disabled(!model.canSave)
            }
            AttachmentChipRow(staging: model.staging, kept: model.kept, onRemove: model.remove)
            HStack(alignment: .bottom, spacing: 4) {
                AttachmentPicker(model: model.staging)
                ComposerInput(text: $model.text, placeholder: "", focusRequest: focusRequest, accessibilityName: "Edit Item") { provider, type in
                    model.staging.importPaste(provider, type: type)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(model.isEmpty ? palette.danger : palette.accent))
                Button {
                    if model.isEmpty { confirmingTrash = true } else { save() }
                } label: {
                    Image(systemName: model.isEmpty ? "trash" : "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.canSave ? palette.onAccent : palette.lineStrong)
                        .frame(width: 40, height: 40)
                        .background(model.canSave ? (model.isEmpty ? palette.danger : palette.accent) : palette.chip, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!model.canSave)
                .accessibilityLabel(model.isEmpty ? ItemEditorModel.moveToTrash : "Save")
                .alert(ItemEditorModel.trashTitle, isPresented: $confirmingTrash) {
                    Button(ItemEditorModel.cancel, role: .cancel) { focusRequest += 1 }
                    Button(ItemEditorModel.moveToTrash, role: .destructive) { save() }
                }
            }
            if let error = model.error ?? actionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.plex(.sansMedium, 13, relativeTo: .footnote))
                    .foregroundStyle(palette.danger)
            }
            if let error = model.staging.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.plex(.sansMedium, 13, relativeTo: .footnote))
                    .foregroundStyle(palette.danger)
            }
        }
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .geometryGroup()
        .onAppear { focusRequest += 1 }
        // An alert restores the keyboard when it closes, which would lift the editor while it slides away.
        .onChange(of: confirmingLeave || confirmingTrash) { _, asking in
            if asking { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .alert(ItemEditorModel.discardTitle, isPresented: Binding(get: { confirmingLeave }, set: { navigation.confirmingLeave = $0 })) {
            Button(ItemEditorModel.keepEditing, role: .cancel) {
                navigation.keepEditing()
                focusRequest += 1
            }
            Button(ItemEditorModel.discardAction, role: .destructive) { navigation.discardAndLeave() }
                .disabled(!model.canSave)
        }
    }

    private func save() {
        guard let outcome = model.save(nowUs: Time.nowUs()) else { return }
        onSaved(outcome)
    }
}

struct EditorBackGestureGuard: UIViewControllerRepresentable {
    let active: Bool
    let blocked: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.active = active
        controller.blocked = blocked
        controller.onAttempt = onAttempt
        DispatchQueue.main.async { controller.install() }
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var active = false
        var blocked = false
        var onAttempt: () -> Void = {}
        weak var gesture: UIGestureRecognizer?
        weak var previousDelegate: UIGestureRecognizerDelegate?
        var previousEnabled = true

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restore()
        }
        func install() {
            guard active else { restore(); return }
            guard let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            if recognizer.delegate !== self {
                previousDelegate = recognizer.delegate
                previousEnabled = recognizer.isEnabled
                gesture = recognizer
                recognizer.delegate = self
                recognizer.isEnabled = true
            }
        }
        func restore() {
            if let gesture, gesture.delegate === self {
                gesture.delegate = previousDelegate
                gesture.isEnabled = previousEnabled
            }
            gesture = nil
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if blocked { onAttempt(); return false }
            return (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
