import NoteBankKit
import QuickLook
import SwiftUI

extension EnvironmentValues {
    @Entry var attachmentTransfers: AttachmentTransfers? = nil
    @Entry var notices: NoticeCenter? = nil
}

struct AttachmentView: View {
    let attachment: FeedAttachment
    var attachments: [FeedAttachment] = []
    @Environment(\.attachmentTransfers) private var transfers
    @Environment(\.notices) private var notices
    @Environment(\.palette) private var palette
    @Environment(\.ruledLine) private var ruledLine
    @State private var thumbnail: URL?
    @State private var thumbnailPending = true
    @State private var preview: URL?
    @State private var shareURL: SharedAttachment?
    @State private var showingImage = false
    @State private var loading = false
    @State private var error: String?
    @State private var pinned = false
    @State private var visible = false
    @State private var noticeID: UUID?

    private var isVideo: Bool { attachment.mimeType.hasPrefix("video/") }

    var body: some View {
        VStack(alignment: .leading, spacing: ruledLine == nil ? 4 : 0) {
            Button {
                guard !loading, let transfers, (try? transfers.canOpen(attachment.id)) == true else { return }
                guard attachment.opensInApp else { noticeID = notices?.postUnsupported(attachment); return }
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
                    catch { self.error = attachmentPreviewFailureMessage(error) }
                    loading = false
                }
            } label: {
                VStack(alignment: .leading, spacing: ruledLine == nil ? 4 : 0) {
                    if let thumbnail, let image = UIImage(contentsOfFile: thumbnail.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: ruledLine.map { 6 * $0 - 8 })
                            .frame(maxHeight: ruledLine == nil ? 180 : nil)
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
                        RoundedRectangle(cornerRadius: 8).fill(palette.chip).frame(maxWidth: .infinity).frame(height: ruledLine.map { 6 * $0 - 8 } ?? 180)
                    } else {
                        HStack(alignment: ruledLine == nil ? .center : .top, spacing: 6) {
                            if loading { ProgressView() } else { Image(systemName: "doc") }
                            Text(attachment.filename).lineLimit(ruledLine == nil ? 2 : nil)
                            Text(ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file)).foregroundStyle(palette.inkMuted)
                        }
                        .font(.plex(.sans, 13, relativeTo: .footnote))
                        .ruledTextSpacing(.sans, 13, relativeTo: .footnote, padsTop: false)
                        .frame(minHeight: ruledLine.map { 2 * $0 - 8 }, alignment: ruledLine == nil ? .leading : .bottomLeading)
                    }
                }
                .padding(.vertical, ruledLine == nil ? 0 : 4)
                .foregroundStyle(palette.ink)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isVideo ? "Play" : "Open") \(attachment.filename)")
            if let error = error ?? attachment.uploadError {
                Label(error, systemImage: "exclamationmark.triangle").font(.plex(.sans, 12, relativeTo: .caption)).foregroundStyle(palette.danger)
                    .ruledTextSpacing(.sans, 12, relativeTo: .caption1)
                    .snapToLines()
            } else if !attachment.uploaded {
                Label(FeedAttachment.pendingLabel, systemImage: "icloud.and.arrow.up").font(.plex(.sans, 12, relativeTo: .caption)).foregroundStyle(palette.inkMuted)
                    .ruledTextSpacing(.sans, 12, relativeTo: .caption1)
                    .snapToLines()
            }
        }
        .task(id: error) {
            guard error != nil, (try? await Task.sleep(for: .seconds(4))) != nil else { return }
            error = nil
        }
        .task(id: attachment) {
            thumbnail = try? await transfers?.thumbnail(attachment.id)
            thumbnailPending = false
        }
        .quickLookPreview($preview)
        .sheet(item: $shareURL, onDismiss: { release() }) { file in
            AttachmentShareSheet(file: file.url)
        }
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
        .onChange(of: notices?.download) { _, request in
            if request?.attachmentID == attachment.id && visible { download() }
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            if let noticeID { notices?.dismiss(id: noticeID) }
            release()
        }
    }

    private func download() {
        guard !loading, shareURL == nil, let transfers, (try? transfers.canOpen(attachment.id)) == true else { return }
        loading = true
        Task {
            do {
                let file = try await transfers.open(attachment.id)
                guard visible else { await transfers.release(attachment.id); loading = false; return }
                pinned = true
                shareURL = SharedAttachment(url: file)
                error = nil
            } catch { self.error = attachmentPreviewFailureMessage(error, headline: "Attachment failed to download.") }
            loading = false
        }
    }

    private func release() {
        guard pinned else { return }
        pinned = false
        Task { await transfers?.release(attachment.id) }
    }
}

private struct SharedAttachment: Identifiable {
    let url: URL
    var id: URL { url }
}
