import Foundation
import UniformTypeIdentifiers
import ImageIO

public enum ItemClipboard {
    public static func text(items: [FeedItem]) -> String? {
        let text = items.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    public static func providers(text: String?, attachments: [(file: URL, mimeType: String)]) throws -> [NSItemProvider] {
        let representations = try contents(text: nil, attachments: attachments)
        var providers = text.map { [NSItemProvider(object: $0 as NSString)] } ?? []
        for (index, item) in representations.enumerated() {
            let provider = NSItemProvider()
            provider.suggestedName = attachments[index].file.lastPathComponent
            for (type, value) in item {
                let data = value as! Data
                provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completed in
                    completed(data, nil)
                    return nil
                }
            }
            providers.append(provider)
        }
        return providers
    }

    public static func contents(text: String?, attachments: [(file: URL, mimeType: String)]) throws -> [[String: Any]] {
        var contents: [[String: Any]] = []
        if let text { contents.append([UTType.utf8PlainText.identifier: text]) }
        for (file, mimeType) in attachments {
            let type = UTType(mimeType: mimeType) ?? UTType(filenameExtension: file.pathExtension) ?? .data
            let bytes = try Data(contentsOf: file)
            var representations: [String: Any] = [type.identifier: bytes]
            if type.conforms(to: .image), type != .png,
               let source = CGImageSourceCreateWithData(bytes as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int,
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
               ] as CFDictionary) {
                let png = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    if CGImageDestinationFinalize(destination) { representations[UTType.png.identifier] = png as Data }
                }
            }
            contents.append(representations)
        }
        return contents
    }
}
