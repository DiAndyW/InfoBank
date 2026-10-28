import AVFoundation
import CoreTransferable
import NoteBankKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct PickedPhoto: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedPhoto(url: target)
        }
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
        .photosPicker(isPresented: $showPhotos, selection: $photos, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photos) { _, selected in
            guard !selected.isEmpty else { return }
            model.beginImport()
            Task {
                defer { model.endImport() }
                for photo in selected {
                    do {
                        guard let imported = try await photo.loadTransferable(type: PickedPhoto.self) else { throw CocoaError(.fileReadUnknown) }
                        await model.importFile(imported.url)
                        try? FileManager.default.removeItem(at: imported.url.deletingLastPathComponent())
                    } catch { model.reportImportError("Couldn't import the selected photo") }
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
                        await model.importFile(url)
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { model.reportImportError("Couldn't open the selected file") }
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

struct StagedAttachmentsView: View {
    let model: ComposerModel
    @Environment(\.palette) private var palette
    var body: some View {
        if model.isImporting { ProgressView("Importing…").font(.caption) }
        if !model.attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.attachments) { attachment in
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Text(attachment.filename).lineLimit(1)
                            Button { model.removeAttachment(attachment.id) } label: { Image(systemName: "xmark").frame(minWidth: 32, minHeight: 44) }
                                .accessibilityLabel("Remove \(attachment.filename)")
                        }
                        .font(.plex(.sans, 13, relativeTo: .footnote))
                        .foregroundStyle(palette.ink)
                        .padding(.leading, 10).padding(.trailing, 2)
                        .background(palette.chip, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}
