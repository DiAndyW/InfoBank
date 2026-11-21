import AVFoundation
import CoreTransferable
import NoteBankKit
import PhotosUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private struct PickedPhoto: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, importing: copy)
        FileRepresentation(importedContentType: .movie, importing: copy)
    }

    @Sendable private static func copy(_ received: ReceivedTransferredFile) throws -> PickedPhoto {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: target)
        return PickedPhoto(url: target)
    }
}

struct AttachmentPicker: View {
    let model: ComposerModel
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @Environment(\.palette) private var palette

    var body: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
            Button("Take Photo", systemImage: "camera") {
                Task {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        model.reportImportError("Camera isn't available on this device")
                        return
                    }
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    if allowed { showCamera = true }
                    else { model.reportImportError("Allow camera access in Settings to take a photo") }
                }
            }
            Button("Files", systemImage: "doc") { showFiles = true }
        } label: {
            Image(systemName: "paperclip").font(.system(size: 19))
                .foregroundStyle(palette.inkMuted).frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach files")
        .disabled(model.isImporting)
        .photosPicker(isPresented: $showPhotos, selection: $photos, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photos) { _, selected in
            guard !selected.isEmpty else { return }
            model.beginImport()
            Task {
                defer { model.endImport() }
                for photo in selected {
                    do {
                        guard let imported = try await photo.loadTransferable(type: PickedPhoto.self) else { throw CocoaError(.fileReadUnknown) }
                        await model.importFile(imported.url, startsOperation: false)
                        try? FileManager.default.removeItem(at: imported.url.deletingLastPathComponent())
                    } catch { model.reportImportError("Photo or video failed to attach.") }
                }
                photos = []
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                model.beginImport()
                Task {
                    defer { model.endImport() }
                    for url in urls {
                        let accessing = url.startAccessingSecurityScopedResource()
                        await model.importFile(url, startsOperation: false)
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { model.reportImportError("File failed to attach.") }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { url in
                showCamera = false
                guard let url else { return }
                Task {
                    await model.importFile(url)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let finished: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (URL?) -> Void
        init(finished: @escaping (URL?) -> Void) { self.finished = finished }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finished(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { finished(nil); return }
            let file = FileManager.default.temporaryDirectory.appending(path: "Photo-\(UUID().uuidString).jpg")
            Task {
                let saved = await Task.detached {
                    guard let data = image.jpegData(compressionQuality: 0.9) else { return false }
                    do { try data.write(to: file); return true } catch { return false }
                }.value
                finished(saved ? file : nil)
            }
        }
    }
}

struct AttachmentChip: View {
    let filename: String
    let mimeType: String
    let sizeBytes: Int64
    let onRemove: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: mimeType.hasPrefix("image/") ? "photo" : mimeType.hasPrefix("video/") ? "play.rectangle" : "doc")
            Text(filename).lineLimit(1).layoutPriority(-1)
            Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                .foregroundStyle(palette.inkMuted).fixedSize()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .foregroundStyle(palette.inkMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(filename)")
        }
        .font(.plex(.sans, 13, relativeTo: .footnote))
        .foregroundStyle(palette.ink)
        .padding(.leading, 10)
        .background(palette.chip, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StagedAttachmentsView: View {
    let model: ComposerModel
    var body: some View {
        AttachmentChipRow(staging: model, onRemove: { model.removeAttachment($0) })
    }
}

struct AttachmentChipRow: View {
    let staging: ComposerModel
    var kept: [FeedAttachment] = []
    let onRemove: (String) -> Void
    @Environment(\.attachmentTransfers) private var transfers
    @Environment(\.palette) private var palette
    @State private var rowWidth: CGFloat = .infinity
    @State private var selected: String?

    private var images: [ImagePreviewItem] {
        kept.filter { AttachmentPresentation(mimeType: $0.mimeType).opensInViewer }.map {
            ImagePreviewItem(id: $0.id, filename: $0.filename, isVideo: $0.mimeType.hasPrefix("video/"))
        } + staging.attachments.filter { AttachmentPresentation(mimeType: $0.mimeType).opensInViewer }.map {
            ImagePreviewItem(id: $0.id, filename: $0.filename, isVideo: $0.mimeType.hasPrefix("video/"))
        }
    }

    private func open(_ id: String) async throws -> URL {
        if staging.attachments.contains(where: { $0.id == id }) { return try staging.stagedFile(id) }
        guard let transfers else { throw AttachmentError("This attachment can't be shown here.") }
        return try await transfers.open(id)
    }

    private func thumbnail(_ id: String) async -> URL? {
        if staging.attachments.contains(where: { $0.id == id }) { return try? staging.stagedFile(id) }
        return try? await transfers?.thumbnail(id)
    }

    private func previewThumbnail(_ id: String) async -> UIImage? {
        guard let url = await thumbnail(id) else { return nil }
        let localVideo = staging.attachments.first(where: { $0.id == id }).map {
            AttachmentPresentation(mimeType: $0.mimeType).needsLocalVideoFrame
        } ?? false
        return await ChipThumbnail.load(url, videoID: localVideo ? id : nil)
    }

    var body: some View {
        if !kept.isEmpty || !staging.attachments.isEmpty || staging.pendingImportCount > 0 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(kept) { attachment in
                        chip(id: attachment.id, filename: attachment.filename, mimeType: attachment.mimeType,
                             sizeBytes: attachment.sizeBytes, hasThumbnail: attachment.hasThumbnail)
                    }
                    ForEach(staging.attachments) { attachment in
                        chip(id: attachment.id, filename: attachment.filename, mimeType: attachment.mimeType,
                             sizeBytes: attachment.sizeBytes, hasThumbnail: false)
                    }
                    if staging.pendingImportCount > 0 { ImportingAttachmentTile(label: staging.pendingImportLabel) }
                }
                .padding(.top, 22)
                .padding(.leading, 10)
                .padding(.trailing, 22)
                .padding(.bottom, 10)
            }
            .background(palette.chip, in: RoundedRectangle(cornerRadius: 12))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .fullScreenCover(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected {
                    ImageViewer(images: images, selectedID: selected, open: open, thumbnail: { id in
                        await previewThumbnail(id)
                    }, release: { id in
                        if kept.contains(where: { $0.id == id }) { Task { await transfers?.release(id) } }
                    })
                }
            }
        }
    }

    @ViewBuilder private func chip(id: String, filename: String, mimeType: String, sizeBytes: Int64, hasThumbnail: Bool) -> some View {
        let presentation = AttachmentPresentation(mimeType: mimeType)
        if presentation == .file {
            AttachmentChip(filename: filename, mimeType: mimeType, sizeBytes: sizeBytes) { onRemove(id) }
                .frame(maxWidth: rowWidth * 0.9)
        } else {
            AttachmentPreviewTile(id: id, filename: filename, isImage: presentation == .image,
                                  source: { presentation == .image || hasThumbnail || staging.attachments.contains(where: { $0.id == id }) ? await previewThumbnail(id) : nil },
                                  onOpen: { selected = id }, onRemove: { onRemove(id) })
        }
    }
}

@MainActor private enum ChipThumbnail {
    static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 16 << 20
        return cache
    }()

    static func load(_ url: URL, videoID: String? = nil) async -> UIImage? {
        let key = videoID.map { URL(string: "staged-video:\($0)")! } ?? url
        if let image = cache.object(forKey: key as NSURL) { return image }
        let image = await Task.detached(priority: .userInitiated) {
            if videoID != nil {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 384, height: 384)
                guard let frame = try? await generator.image(at: .zero) else { return UIImage?.none }
                return UIImage(cgImage: frame.image)
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 384,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return UIImage?.none }
            return UIImage(cgImage: cg)
        }.value
        if let image { cache.setObject(image, forKey: key as NSURL, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)) }
        return image
    }
}

struct AttachmentPreviewTile: View {
    let id: String
    let filename: String
    let isImage: Bool
    let source: () async -> UIImage?
    let onOpen: () -> Void
    let onRemove: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var chipTextHeight = 18
    @Environment(\.palette) private var palette
    @State private var image: UIImage?
    @State private var loading = true

    private var side: CGFloat { max(44, chipTextHeight) * 1.6 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) { tile }
                .buttonStyle(.plain)
                .accessibilityLabel((isImage ? AttachmentPresentation.image : .video).previewLabel(filename: filename))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(5)
                    .background(palette.surfaceRaised, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(filename)")
            .offset(x: 22, y: -22)
        }
        .foregroundStyle(palette.ink)
        .task(id: id) {
            loading = true
            image = await source()
            loading = false
        }
    }

    private var tile: some View {
        ZStack {
            palette.chip
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if loading { ProgressView().accessibilityLabel("Loading preview") }
            else { Image(systemName: isImage ? "photo" : "play.rectangle").foregroundStyle(palette.inkMuted) }
            if !isImage && !loading { Image(systemName: "play.circle.fill").font(.largeTitle).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55)).shadow(radius: 2) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ImportingAttachmentTile: View {
    let label: String
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .footnote) private var chipTextHeight = 18
    var body: some View {
        HStack {
            ProgressView()
            Text(label).font(.plex(.sans, 13, relativeTo: .footnote))
        }
            .padding(.horizontal, 10)
            .frame(minHeight: max(44, chipTextHeight) * 1.6)
            .background(palette.chip, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(label)
    }
}
