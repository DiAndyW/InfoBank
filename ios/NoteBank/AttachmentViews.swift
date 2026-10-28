import NoteBankKit
import QuickLook
import SwiftUI

extension EnvironmentValues {
    @Entry var attachmentTransfers: AttachmentTransfers? = nil
}

struct AttachmentView: View {
    let attachment: FeedAttachment
    @Environment(\.attachmentTransfers) private var transfers
    @Environment(\.palette) private var palette
    @State private var thumbnail: URL?
    @State private var preview: URL?
    @State private var loading = false
    @State private var error: String?
    @State private var pinned = false
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !loading, let transfers else { return }
                loading = true
                Task {
                    do {
                        let file = try await transfers.open(attachment.id)
                        guard visible else { await transfers.release(attachment.id); loading = false; return }
                        preview = file
                        pinned = true
                        error = nil
                    }
                    catch { self.error = error.localizedDescription }
                    loading = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let thumbnail, let image = UIImage(contentsOfFile: thumbnail.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay { if loading { ProgressView().padding(8).background(.regularMaterial, in: Circle()) } }
                    } else {
                        HStack(spacing: 6) {
                            if loading { ProgressView() } else { Image(systemName: "doc") }
                            Text(attachment.filename).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file)).foregroundStyle(palette.inkMuted)
                        }
                        .font(.plex(.sans, 13, relativeTo: .footnote))
                    }
                }
                .foregroundStyle(palette.ink)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(attachment.filename)")
            if let error = error ?? attachment.uploadError {
                Label(error, systemImage: "exclamationmark.triangle").font(.plex(.sans, 12, relativeTo: .caption)).foregroundStyle(palette.danger)
            }
        }
        .task(id: attachment) { thumbnail = try? await transfers?.thumbnail(attachment.id) }
        .quickLookPreview($preview)
        .onChange(of: preview) { _, value in
            if value == nil { release() }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; release() }
    }

    private func release() {
        guard pinned else { return }
        pinned = false
        Task { await transfers?.release(attachment.id) }
    }
}
