import NoteBankKit
import SwiftUI
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private var importTask: Task<Void, Never>?
    private var model: ShareCaptureModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            let store = try Store(at: Store.appGroupFile())
            guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, prefix.hasSuffix(".") else {
                throw StoreError.noAppGroup
            }
            let secrets = SecretStore.keychain(accessGroup: prefix + "app.notebank.shared")
            let model = ShareCaptureModel(store: store)
            self.model = model
            let inputs = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            // Disable Save before the first render, including text supplied by the host.
            model.beginImport()
            let view = ShareComposer(model: model, store: store, secrets: secrets, cancel: { [weak self] in self?.cancel() }, finish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
            embed(UIHostingController(rootView: view))
            importTask = Task {
                defer { model.endImport() }
                await importSharedInputs(inputs, store: store, model: model)
            }
        } catch {
            embed(UIHostingController(rootView: ContentUnavailableView {
                Label("Couldn't open NoteBank", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Open NoteBank once, then try sharing again.")
            } actions: {
                Button("Cancel") { [weak self] in self?.cancel() }
            }))
        }
    }

    private func embed(_ controller: UIViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func cancel() {
        importTask?.cancel()
        model?.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

private struct ShareComposer: View {
    @Bindable var model: ShareCaptureModel
    let store: Store
    let secrets: SecretStore
    let cancel: () -> Void
    let finish: () -> Void
    @AppStorage("tunnelSwitch", store: UserDefaults(suiteName: "group.app.notebank")) private var tunnelOn = false
    @State private var saving = false
    @State private var savedMessage: String?
    @State private var deliveryTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let savedMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Saved to NoteBank").font(.title2.weight(.semibold))
                        if !savedMessage.isEmpty {
                            Text(savedMessage).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    Form {
                        Section("Add text") {
                            TextField("Optional text…", text: $model.extraText, axis: .vertical)
                                .lineLimit(3...8)
                        }
                        if model.isImporting { Section { ProgressView("Loading shared content…") } }
                        if !model.sharedText.isEmpty {
                            Section("Shared content") {
                                Text(model.sharedText).lineLimit(8).textSelection(.enabled)
                            }
                        }
                        if !model.attachments.isEmpty {
                            Section("Attachments") {
                                ForEach(model.attachments) { file in
                                    Label(file.filename, systemImage: "paperclip")
                                        .font(.subheadline)
                                        .lineLimit(2)
                                }
                            }
                        }
                        Section {
                            Toggle("Tunnel", isOn: $tunnelOn)
                            if !tunnelOn {
                                Picker("Save to", selection: $model.destination) {
                                    Text("Inbox").tag(Destination.inbox)
                                    ForEach(model.topics) { topic in
                                        Text(topic.name).tag(Destination.topic(topic.id))
                                    }
                                }
                            }
                        }
                        if let error = model.error {
                            Section { Text(error).foregroundStyle(.red).accessibilityLabel(error) }
                        }
                        if saving { Section { ProgressView("Saved locally. Sending…") } }
                    }
                }
            }
            .disabled(saving)
            .navigationTitle("NoteBank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.savedItemID == nil { Button("Cancel", action: cancel).disabled(saving) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if savedMessage != nil {
                        Button("Done", action: finish)
                    } else {
                        Button("Save") { save() }.disabled(saving || !model.canSave)
                    }
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onDisappear { deliveryTask?.cancel() }
    }

    private func save() {
        guard !saving else { return }
        let destination = model.destination
        if tunnelOn { model.destination = .tunnel }
        guard let id = model.save() else {
            model.destination = destination
            return
        }
        saving = true
        deliveryTask = Task {
            let transfers = AttachmentTransfers(store: store, secrets: secrets, sessionIdentifier: AttachmentTransfers.shareSessionIdentifier)
            let result = await deliverSharedCapture(id, store: store, secrets: secrets, transfers: transfers)
            saving = false
            switch result {
            case .sent:
                savedMessage = ""
            case .sentToInbox:
                savedMessage = "Saved to Inbox because the selected Topic is no longer available"
            case .refused:
                savedMessage = "The Server refused this Capture, but it's saved to your iPhone. Open NoteBank to review it"
            case .savedLocally:
                savedMessage = "Saved on this iPhone. Open NoteBank to finish syncing"
            }
        }
    }
}
