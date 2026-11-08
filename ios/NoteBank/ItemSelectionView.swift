import NoteBankKit
import Observation
import SwiftUI

@MainActor @Observable
final class BatchItemActions {
    let selection = ItemSelection()
    private let store: Store
    private let transfers: AttachmentTransfers
    private let notices: NoticeCenter
    private let wake: () -> Void
    private(set) var busy = false
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var generation = 0

    init(services: Services) {
        store = services.store
        transfers = services.transfers
        notices = services.notices
        wake = services.wake
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        busy = false
        selection.clear()
    }

    func reconcile(_ items: [FeedItem]) {
        let previous = selection.ids
        selection.reconcile(items.filter { $0.syncError == nil }.map(\.id))
        if previous != selection.ids && busy { cancel() }
    }

    func run(_ ids: [String], restore: Bool = false) {
        guard !busy, !ids.isEmpty else { return }
        do {
            if restore {
                try store.restore(itemIDs: ids, nowUs: Time.nowUs())
                notices.postBatchCompleted(count: ids.count, copied: false)
            } else {
                try store.trash(itemIDs: ids, nowUs: Time.nowUs())
                notices.postTrashed(itemIDs: ids, copied: false)
            }
            selection.clear()
            wake()
        } catch { self.error = error.localizedDescription }
    }

    func copy(_ ids: [String], trash: Bool) {
        guard !busy, !ids.isEmpty else { return }
        busy = true
        let version = generation
        task = Task { @MainActor in
            defer { if generation == version { busy = false; task = nil } }
            var copied = false
            var files: [URL] = []
            defer {
                if !copied, let folder = files.first?.deletingLastPathComponent().deletingLastPathComponent() {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            do {
                let items = try store.items(ids: ids)
                let attachments = items.flatMap(\.attachments)
                files = try await transfers.clipboardFiles(attachments.map(\.id))
                try Task.checkCancellation()
                guard generation == version, UIApplication.shared.applicationState == .active else { return }
                let current = try store.items(ids: ids)
                guard zip(items, current).allSatisfy({ before, after in
                    before.text == after.text && before.attachments.map(\.id) == after.attachments.map(\.id) &&
                    zip(before.attachments, after.attachments).allSatisfy { a, b in
                        a.filename == b.filename && a.mimeType == b.mimeType && a.sizeBytes == b.sizeBytes
                    }
                }) else { throw AttachmentError("An Item changed while preparing the copy; copy it again") }
                let providers = try ItemClipboard.providers(text: ItemClipboard.text(items: items), attachments: zip(attachments, files).map {
                    (file: $0.1, mimeType: $0.0.mimeType)
                })
                guard !providers.isEmpty else { throw AttachmentError("The selected Items are empty") }
                let board = UIPasteboard.general
                let previous = board.changeCount
                board.setItemProviders(providers, localOnly: false, expirationDate: Date().addingTimeInterval(7 * 24 * 3600))
                guard board.changeCount != previous, board.numberOfItems == providers.count else {
                    throw AttachmentError("Couldn't copy all selected Items")
                }
                copied = true
                if trash {
                    try store.trash(itemIDs: ids, nowUs: Time.nowUs())
                    notices.postTrashed(itemIDs: ids, copied: true)
                    wake()
                } else { notices.postBatchCompleted(count: ids.count, copied: true) }
                selection.clear()
            } catch is CancellationError {
            } catch {
                if generation == version { self.error = (copied ? "Items copied, but couldn't move them to Trash. " : "") + error.localizedDescription }
            }
        }
    }
}

struct BatchActionsBar: View {
    let batch: BatchItemActions
    let items: [FeedItem]
    var trash = false
    var tunnel = false
    @Environment(\.palette) private var palette

    private var ids: [String] { batch.selection.orderedIDs(in: items.map(\.id)) }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(ids.count) selected")
                .font(.plex(.sansSemibold, 12, relativeTo: .caption))
                .foregroundStyle(palette.inkMuted)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if trash {
                    Button { batch.run(ids, restore: true) } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward").frame(minHeight: 24)
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button { batch.copy(ids, trash: tunnel) } label: {
                        Label(tunnel ? "Copy & Trash" : "Copy", systemImage: "doc.on.doc").frame(minHeight: 24)
                    }.buttonStyle(.borderedProminent)
                    Button(role: .destructive) { batch.run(ids) } label: {
                        Label("Trash", systemImage: "trash").frame(minHeight: 24)
                    }.buttonStyle(.bordered)
                }
            }
            .font(.plex(.sansSemibold, 13))
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(batch.busy || ids.isEmpty)
        }
        .frame(minHeight: 44)
        .tint(palette.accent)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(palette.surfaceSidebar.ignoresSafeArea(edges: .bottom))
    }
}

struct ItemNoticeView: View {
    let notices: NoticeCenter
    let store: Store
    let wake: () -> Void
    let onShow: (String) -> Void
    let onError: (String) -> Void
    let onUndoClear: (DraftPlace) -> Void

    var body: some View {
        if let notice = notices.current {
            NoticeView(message: notice.message, actionTitle: notice.actionTitle, onAction: {
                do {
                    switch notice.action {
                    case .undoClear(let place): onUndoClear(place); notices.dismiss(); return
                    case .undoTrash: try store.restore(itemID: notice.itemID, nowUs: Time.nowUs())
                    case .undoBatchTrash(let ids): try store.restore(itemIDs: ids, nowUs: Time.nowUs())
                    case .undoMove(let destination): try store.move(itemID: notice.itemID, to: destination, nowUs: Time.nowUs())
                    case .show: onShow(notice.itemID); return
                    case .dismiss: notices.dismiss(); return
                    }
                    notices.dismiss()
                    wake()
                } catch { onError(error.localizedDescription) }
            }, onDismiss: notices.dismiss)
            .id(notice.id)
            .padding(12)
        }
    }
}
