import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main
struct ImageChecks: App {
    var body: some Scene { WindowGroup { Checks() } }
}

struct Checks: View {
    @State private var finished = false
    var body: some View {
        Text(finished ? "Image viewer checks passed" : "Checking image viewer")
            .task { await check(); finished = true }
    }

    @MainActor
    private func check() async {
        var results: [String] = []
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("image.jpg")
        try! image.jpegData(compressionQuality: 0.9)!.write(to: file)
        let state = ImagePreviewState(thumbnail: image)
        assert(state.image === image && state.file == nil)
        results.append("thumbnail is available before original loading")
        var releases = 0
        await state.load(open: { file }, release: { releases += 1 })
        assert(state.file == file && state.image != nil && state.error == nil && !state.loading)
        assert(releases == 0)
        state.close(); state.close()
        assert(releases == 1 && state.file == nil)
        results.append("original remains pinned until close and releases exactly once")

        let failed = ImagePreviewState(thumbnail: image)
        await failed.load(open: { throw CocoaError(.fileReadNoSuchFile) }, release: { releases += 1 })
        assert(failed.image === image && failed.error != nil && failed.file == nil && !failed.loading)
        assert(releases == 1)
        await failed.load(open: { file }, release: { releases += 1 })
        assert(failed.file == file && failed.error == nil)
        failed.close()
        assert(releases == 2)
        results.append("download failure preserves thumbnail and retry succeeds")

        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent("broken.jpg")
        try! Data("invalid image".utf8).write(to: corrupt)
        let invalid = ImagePreviewState(thumbnail: image)
        await invalid.load(open: { corrupt }, release: { releases += 1 })
        assert(invalid.image === image && invalid.error != nil && invalid.file == nil && releases == 3)
        results.append("invalid image preserves thumbnail and releases original")

        let closing = ImagePreviewState(thumbnail: image)
        var resume: CheckedContinuation<URL, Never>?
        let task = Task { await closing.load(open: { await withCheckedContinuation { resume = $0 } }, release: { releases += 1 }) }
        while resume == nil { await Task.yield() }
        assert(closing.loading)
        closing.close()
        resume!.resume(returning: file)
        await task.value
        assert(closing.file == nil && releases == 4 && !closing.loading)
        results.append("closing during download releases late completion")

        let cancelled = ImagePreviewState(thumbnail: image)
        resume = nil
        let cancelledTask = Task { await cancelled.load(open: { await withCheckedContinuation { resume = $0 } }, release: { releases += 1 }) }
        while resume == nil { await Task.yield() }
        cancelledTask.cancel()
        resume!.resume(returning: file)
        await cancelledTask.value
        assert(cancelled.file == nil && cancelled.error == nil && releases == 5)
        results.append("task cancellation releases late completion without an error")

        let zoom = ZoomingImageView()
        zoom.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        zoom.setImage(image)
        zoom.layoutIfNeeded()
        assert(zoom.minimumZoomScale == 1 && zoom.maximumZoomScale > 1)
        zoom.setZoomScale(2, animated: false)
        zoom.setImage(image)
        assert(zoom.zoomScale == 2)
        zoom.setImage(UIImage(cgImage: image.cgImage!))
        assert(zoom.zoomScale == 1)
        results.append("zoom survives unchanged image updates and resets for replacement")

        let rotated = FileManager.default.temporaryDirectory.appendingPathComponent("rotated.jpg")
        let destination = CGImageDestinationCreateWithURL(rotated as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        assert(CGImageDestinationFinalize(destination))
        let oriented = ImagePreviewState(thumbnail: nil)
        await oriented.load(open: { rotated }, release: {})
        assert(oriented.image?.size == CGSize(width: 80, height: 120))
        oriented.close()
        results.append("EXIF rotation is applied to the displayed image")

        let large = UIGraphicsImageRenderer(size: CGSize(width: 6000, height: 20), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 6000, height: 20))
        }
        let largeFile = FileManager.default.temporaryDirectory.appendingPathComponent("large.jpg")
        try! large.jpegData(compressionQuality: 0.9)!.write(to: largeFile)
        let bounded = ImagePreviewState(thumbnail: nil)
        await bounded.load(open: { largeFile }, release: {})
        assert(bounded.image?.size.width == 4096 && bounded.file == largeFile)
        bounded.close()
        results.append("large images decode within 4096 pixels while retaining the original for sharing")

        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
        try! JSONSerialization.data(withJSONObject: results).write(to: output)
    }
}
