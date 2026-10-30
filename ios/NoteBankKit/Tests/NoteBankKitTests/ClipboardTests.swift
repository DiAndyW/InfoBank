import Foundation
import Testing
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics
@testable import NoteBankKit

struct ClipboardTests {
    @Test func copiedProvidersKeepOriginalFilenamesAndBytesWithoutPrivateURLs() async throws {
        let source = try AttachmentTests().source(Data([1, 2, 3]), name: "IMG_0111.heic")
        defer { try? FileManager.default.removeItem(at: source) }
        let providers = try ItemClipboard.providers(text: "caption", attachments: [(file: source, mimeType: "image/heic")])
        #expect(providers.count == 2)
        #expect(providers[1].suggestedName == "IMG_0111.heic")
        #expect(!providers[1].hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            providers[1].loadDataRepresentation(forTypeIdentifier: UTType.heic.identifier) { bytes, error in
                if let bytes { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        #expect(data == Data([1, 2, 3]))
    }

    @Test func nonPNGImagesOfferAPortablePNGAlongsideTheirOriginalBytes() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        let jpeg = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let source = try AttachmentTests().source(jpeg as Data, name: "photo.jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let items = try ItemClipboard.contents(text: "caption", attachments: [(file: source, mimeType: "image/jpeg")])
        #expect(items[0][UTType.utf8PlainText.identifier] as? String == "caption")
        #expect(items[1][UTType.jpeg.identifier] as? Data == original)
        let png = try #require(items[1][UTType.png.identifier] as? Data)
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let decoded = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(image.width == 3 && image.height == 2)
        #expect(items[1][UTType.fileURL.identifier] == nil)
    }

    @Test func mixedItemPreservesTextAndOriginalBytesWithoutAdvertisingPrivateURLs() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "photo.heic")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: image)
        let items = try ItemClipboard.contents(text: "Test\nsecond line", attachments: [(file: image, mimeType: "image/heic")])
        #expect(items.count == 2)
        #expect(items[0][UTType.utf8PlainText.identifier] as? String == "Test\nsecond line")
        #expect(items[1][UTType.heic.identifier] as? Data == bytes)
        #expect(!items.contains { $0[UTType.fileURL.identifier] != nil })
    }

    @Test func attachmentOnlyItemContainsFileDataAndNoPathFallback() throws {
        let source = try AttachmentTests().source()
        defer { try? FileManager.default.removeItem(at: source) }
        let items = try ItemClipboard.contents(text: nil, attachments: [(file: source, mimeType: "text/plain")])
        #expect(items.count == 1)
        #expect(items[0][UTType.plainText.identifier] as? Data == Data("hello".utf8))
        #expect(items[0][UTType.fileURL.identifier] == nil)
    }

    @Test func missingOriginalCannotProduceAPartialClipboard() throws {
        #expect(throws: (any Error).self) {
            try ItemClipboard.contents(text: "keep me", attachments: [(file: URL(fileURLWithPath: "/missing/" + UUID().uuidString), mimeType: "application/pdf")])
        }
    }
}
