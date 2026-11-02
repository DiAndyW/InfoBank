import AVFoundation
import SwiftUI

@main
struct GalleryChecksApp: App {
    var body: some Scene { WindowGroup { GalleryFixture() } }
}

struct GalleryFixture: View {
    @State private var showing = false
    @State private var failedOnce = false
    @State private var showingVideo = false
    private let images: [ImagePreviewItem] = ["first", "second", "third"].enumerated().map { index, name in
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { context in
            [UIColor.systemTeal, .systemOrange, .systemPurple][index].setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            (name as NSString).draw(at: CGPoint(x: 100, y: 180), withAttributes: [.font: UIFont.systemFont(ofSize: 54), .foregroundColor: UIColor.white])
        }
        return ImagePreviewItem(id: name, filename: name + ".jpg", thumbnail: image)
    }

    var body: some View {
        Button("Open images") { showing = true }
            .fullScreenCover(isPresented: $showing) {
                ImageViewer(images: images, selectedID: "first", open: { id in
                    try await Task.sleep(for: .seconds(1))
                    if ProcessInfo.processInfo.arguments.contains("--failure"), !failedOnce {
                        failedOnce = true
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".jpg")
                    try images.first(where: { $0.id == id })!.thumbnail!.jpegData(compressionQuality: 0.9)!.write(to: file)
                    return file
                }, thumbnail: { _ in nil }, release: { _ in })
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--record") {
                    try? await Task.sleep(for: .seconds(3))
                    showing = true
                }
            }
        Button("Open video") { showingVideo = true }
            .fullScreenCover(isPresented: $showingVideo) {
                ImageViewer(images: [ImagePreviewItem(id: "clip", filename: "clip.mp4", isVideo: true), images[0]], selectedID: "clip", open: { id in
                    if id == "clip" { return try await makeVideo() }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".jpg")
                    try images[0].thumbnail!.jpegData(compressionQuality: 0.9)!.write(to: file)
                    return file
                }, thumbnail: { _ in nil }, release: { _ in })
            }
    }
}

@MainActor
private func makeVideo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip.mp4")
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<90 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 3 % 255), CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    return url
}
