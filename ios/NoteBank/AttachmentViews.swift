import NoteBankKit
import QuickLook
import SwiftUI

extension EnvironmentValues {
    @Entry var attachmentTransfers: AttachmentTransfers? = nil
}

struct AttachmentView: View {
    let attachment: FeedAttachment
    var attachments: [FeedAttachment] = []
    @Environment(\.attachmentTransfers) private var transfers
    @Environment(\.palette) private var palette
    @State private var thumbnail: URL?
    @State private var thumbnailPending = true
    @State private var preview: URL?
    @State private var showingImage = false
    @State private var loading = false
    @State private var error: String?
    @State private var pinned = false
    @State private var visible = false

    private var isVideo: Bool { attachment.mimeType.hasPrefix("video/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !loading, let transfers else { return }
                if attachment.mimeType.hasPrefix("image/") || isVideo {
                    showingImage = true
                    return
                }
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
                            .overlay {
                                if loading { ProgressView().padding(8).background(.regularMaterial, in: Circle()) }
                                else if isVideo {
                                    Image(systemName: "play.circle.fill").font(.largeTitle)
                                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
                                        .shadow(radius: 2)
                                }
                            }
                    } else if thumbnailPending && (attachment.mimeType.hasPrefix("image/") || isVideo) {
                        // Reserves the thumbnail's height so rows don't grow after the Feed scrolls to an Item.
                        RoundedRectangle(cornerRadius: 8).fill(palette.chip).frame(maxWidth: .infinity).frame(height: 180)
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
            .accessibilityLabel("\(isVideo ? "Play" : "Open") \(attachment.filename)")
            if let error = error ?? attachment.uploadError {
                Label(error, systemImage: "exclamationmark.triangle").font(.plex(.sans, 12, relativeTo: .caption)).foregroundStyle(palette.danger)
            }
        }
        .task(id: attachment) {
            thumbnail = try? await transfers?.thumbnail(attachment.id)
            thumbnailPending = false
        }
        .quickLookPreview($preview)
        .fullScreenCover(isPresented: $showingImage, onDismiss: {
            if thumbnail == nil { Task { thumbnail = try? await transfers?.thumbnail(attachment.id) } }
        }) {
            if let transfers {
                ImageViewer(
                    images: (attachments.isEmpty ? [attachment] : attachments)
                        .filter { $0.mimeType.hasPrefix("image/") || $0.mimeType.hasPrefix("video/") }
                        .map { image in
                            ImagePreviewItem(id: image.id, filename: image.filename,
                                             thumbnail: image.id == attachment.id ? thumbnail.flatMap { UIImage(contentsOfFile: $0.path) } : nil,
                                             isVideo: image.mimeType.hasPrefix("video/"))
                        },
                    selectedID: attachment.id,
                    open: { try await transfers.open($0) },
                    thumbnail: { id in
                        guard let url = try? await transfers.thumbnail(id) else { return nil }
                        return UIImage(contentsOfFile: url.path)
                    },
                    release: { id in Task { await transfers.release(id) } }
                )
            }
        }
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
