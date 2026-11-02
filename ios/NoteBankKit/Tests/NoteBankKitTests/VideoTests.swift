import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import NoteBankKit

func makeMovie(width: Int = 640, height: Int = 360, rotated: Bool = false, frames: Int = 10, timescale: Int32 = 10) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/clip.mov")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: timescale))
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return url
}

struct VideoTests {
    func sparseFile(_ name: String, bytes: Int64) throws -> URL {
        let file = try AttachmentTests().source(Data(), name: name)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return file
    }

    @Test func overLimitVideoIsToldToTrimAndOtherFilesAreNot() throws {
        let (store, _) = try tempStore()
        let video = try sparseFile("clip.mov", bytes: Store.maxAttachmentBytes + 1)
        let videoError = #expect(throws: AttachmentError.self) { try store.stageFile(at: video) }
        #expect(videoError?.message == "clip.mov is over 100 MB. Trim the video and try again.")
        let other = try sparseFile("data.bin", bytes: Store.maxAttachmentBytes + 1)
        let otherError = #expect(throws: AttachmentError.self) { try store.stageFile(at: other) }
        #expect(otherError?.message == "data.bin is over 100 MB")
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM staged_files") } == 0)
    }

    @Test func videoExactlyAtTheLimitStages() throws {
        let (store, _) = try tempStore()
        let staged = try store.stageFile(at: sparseFile("clip.mov", bytes: Store.maxAttachmentBytes))
        #expect(staged.mimeType == "video/quicktime" && staged.sizeBytes == Store.maxAttachmentBytes)
    }

    @Test func posterIsMadeFromTheLocalOriginalAndKeepsItsOrientation() async throws {
        for (rotated, expected) in [(false, (400, 225)), (true, (225, 400))] {
            let (store, _) = try tempStore()
            let transfers = AttachmentTransfers(store: store, secrets: .memory(), background: false)
            let staged = try store.stageFile(at: await makeMovie(rotated: rotated))
            _ = try store.capture(text: "clip", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
            let poster = try #require(try await transfers.thumbnail(staged.id))
            let bytes = try Data(contentsOf: poster)
            #expect(bytes.prefix(2) == Data([0xff, 0xd8]))
            let image = try #require(CGImageSourceCreateWithData(bytes as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect((image.width, image.height) == expected)
            #expect(try store.localFile(staged.id, kind: "thumbnail") == poster)
        }
    }

    @Test func clipShorterThanThePosterTimeStillGetsAPoster() async throws {
        let (store, _) = try tempStore()
        let transfers = AttachmentTransfers(store: store, secrets: .memory(), background: false)
        let staged = try store.stageFile(at: await makeMovie(frames: 1, timescale: 1000))
        _ = try store.capture(text: "clip", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
        #expect(try await transfers.thumbnail(staged.id) != nil)
    }

    @Test func videoWithoutALocalOriginalGetsNoPosterAndDownloadsNothing() async throws {
        let server = try await FakeServer { _ in .init(status: 500) }
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: "secret", secrets: secrets)
        let staged = try store.stageFile(at: await makeMovie())
        _ = try store.capture(text: "clip", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE attachments SET uploaded = 1 WHERE id = ?", arguments: [staged.id])
            try db.execute(sql: "DELETE FROM cached_files WHERE attachment_id = ?", arguments: [staged.id])
        }
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        #expect(try await transfers.thumbnail(staged.id) == nil)
        #expect(server.requests(to: "/attachments/\(staged.id)") == 0)
        #expect(server.requests(to: "/attachments/\(staged.id)/thumbnail") == 0)
    }

    @Test func posterUploadsAndOtherDeviceSeesItWithoutDownloadingTheMovie() async throws {
        let server = try TestServer(); try await server.start()
        let (store, _) = try tempStore(); let secrets = SecretStore.memory()
        try store.saveSettings(url: server.url, newSecret: server.secret, secrets: secrets)
        let staged = try store.stageFile(at: await makeMovie())
        _ = try store.capture(text: "clip", attachmentIDs: [staged.id], to: .inbox, nowUs: Time.nowUs())
        var notices: [SyncNotice] = []
        _ = try await cycle(store: store, secrets: secrets, http: .live, queued: &notices)
        let transfers = AttachmentTransfers(store: store, secrets: secrets, background: false)
        try await transfers.synchronize()
        #expect(try store.localFile(staged.id, kind: "thumbnail") != nil)
        for _ in 0..<200 {
            if try store.attachment(staged.id)?.uploaded == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await transfers.synchronize()
        _ = try await cycle(store: store, secrets: secrets, http: .live, queued: &notices)
        #expect(try store.attachment(staged.id)?.hasThumbnail == true)
        let (other, _) = try tempStore(); let otherSecrets = SecretStore.memory()
        try other.saveSettings(url: server.url, newSecret: server.secret, secrets: otherSecrets)
        _ = try await cycle(store: other, secrets: otherSecrets, http: .live, queued: &notices)
        #expect(try other.attachment(staged.id)?.hasThumbnail == true)
        let poster = try #require(try await AttachmentTransfers(store: other, secrets: otherSecrets, background: false).thumbnail(staged.id))
        #expect(try Data(contentsOf: poster).prefix(2) == Data([0xff, 0xd8]))
        #expect(try other.localFile(staged.id) == nil)
    }

    @Test @MainActor func sharedMovieIsStagedAsAVideoAttachment() async throws {
        let (store, _) = try tempStore()
        let model = ShareCaptureModel(store: store)
        let movie = try await makeMovie()
        let provider = try #require(NSItemProvider(contentsOf: movie))
        await importSharedInputs([provider], store: store, model: model)
        #expect(model.error == nil)
        #expect(model.attachments.map(\.mimeType) == ["video/quicktime"])
        #expect(model.attachments.map(\.sizeBytes) == [Int64(try Data(contentsOf: movie).count)])
    }
}
