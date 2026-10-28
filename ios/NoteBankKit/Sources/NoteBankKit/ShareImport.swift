import Foundation
import UniformTypeIdentifiers

@MainActor
public func importSharedInputs(_ providers: [NSItemProvider], store: Store, model: ShareCaptureModel) async {
    model.beginImport()
    defer { model.endImport() }
    guard !providers.isEmpty else { model.reportImportError(); return }
    for provider in providers {
        guard !Task.isCancelled else { model.cancel(); return }
        do {
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            let hasURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            let hasText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            let filename = provider.suggestedName
            let isNamedFile = filename.map { !($0 as NSString).pathExtension.isEmpty } ?? false
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let file: StagedAttachment = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                        do {
                            if let error { throw error }
                            guard let url = sharedURL(item), url.isFileURL else { throw AttachmentError("Couldn't load this file") }
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            continuation.resume(returning: try store.stageFile(at: url, filename: filename))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                if Task.isCancelled { try? store.discardStaged(file.id); model.cancel(); return }
                model.addAttachment(file)
            } else if let type = types.first(where: {
                $0.conforms(to: .data) && !$0.conforms(to: .url) &&
                (!$0.conforms(to: .text) || (isNamedFile && !hasURL)) &&
                ($0 != .data || (!hasURL && !hasText))
            }) {
                let file: StagedAttachment = try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        do {
                            if let error { throw error }
                            guard let url else { throw AttachmentError("Couldn't load this file") }
                            var name = filename ?? url.lastPathComponent
                            if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
                            continuation.resume(returning: try store.stageFile(at: url, filename: name))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                if Task.isCancelled { try? store.discardStaged(file.id); model.cancel(); return }
                model.addAttachment(file)
            } else if hasURL {
                let text: String = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let url = sharedURL(item), !url.isFileURL { continuation.resume(returning: url.absoluteString) }
                        else { continuation.resume(throwing: AttachmentError("Couldn't load this link")) }
                    }
                }
                model.appendText(text)
            } else if hasText {
                let text: String = try await withCheckedThrowingContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let text = item as? String { continuation.resume(returning: text) }
                        else if let data = item as? Data, let text = String(data: data, encoding: .utf8) { continuation.resume(returning: text) }
                        else { continuation.resume(throwing: AttachmentError("Couldn't load this text")) }
                    }
                }
                model.appendText(text)
            } else { throw AttachmentError("Couldn't load this shared content") }
        } catch {
            model.reportImportError()
            return
        }
    }
}

private func sharedURL(_ item: (any NSSecureCoding)?) -> URL? {
    if let url = item as? URL { return url }
    let text: String?
    if let string = item as? String { text = string }
    else if let data = item as? Data { text = String(data: data, encoding: .utf8) }
    else { text = nil }
    return text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
