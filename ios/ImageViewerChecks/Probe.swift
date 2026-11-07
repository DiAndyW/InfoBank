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

        let video = ImagePreviewState(thumbnail: image, isVideo: true)
        var videoReleases = 0
        await video.load(open: { corrupt }, release: { videoReleases += 1 })
        assert(video.file == corrupt && video.player != nil && video.error == nil && video.image === image)
        video.close(); video.close()
        assert(video.player == nil && video.file == nil && videoReleases == 1)
        results.append("a video is handed to a player without image decoding and released once on close")

        let decoded = NSCache<NSString, UIImage>()
        let first = ImagePreviewState(thumbnail: image, id: "a", decoded: decoded)
        assert(first.image === image)
        await first.load(open: { file }, release: {})
        let original = first.image!
        assert(original !== image && decoded.object(forKey: "a") === original)
        first.close()
        let reopened = ImagePreviewState(thumbnail: image, id: "a", decoded: decoded)
        assert(reopened.image === original && reopened.file == nil)
        results.append("reopening immediately reuses the decoded original")

        var cachedReleases = 0
        await reopened.load(open: {
            assert(!reopened.loading)
            return file
        }, release: { cachedReleases += 1 })
        assert(reopened.image === original && reopened.file == file && reopened.error == nil)
        reopened.close(); reopened.close()
        assert(cachedReleases == 1 && reopened.file == nil && reopened.image === image)
        results.append("cache hit opens without a spinner and pins the file until close")

        let cachedFailure = ImagePreviewState(thumbnail: image, id: "a", decoded: decoded)
        await cachedFailure.load(open: {
            assert(!cachedFailure.loading)
            throw CocoaError(.fileReadNoSuchFile)
        }, release: { cachedReleases += 1 })
        assert(cachedFailure.image === original && cachedFailure.file == nil)
        assert(cachedFailure.error != nil && !cachedFailure.loading && cachedReleases == 1)
        results.append("cache hit preserves the sharp image when opening the file fails")

        let invalidCached = ImagePreviewState(thumbnail: image, id: "broken", decoded: decoded)
        await invalidCached.load(open: { corrupt }, release: {})
        assert(invalidCached.error != nil && decoded.object(forKey: "broken") == nil)
        results.append("failed decoding never populates the cache")

        let cachedVideo = ImagePreviewState(thumbnail: image, isVideo: true, id: "a", decoded: decoded)
        assert(cachedVideo.image === image)
        await cachedVideo.load(open: { corrupt }, release: {})
        assert(cachedVideo.image === image && decoded.object(forKey: "a") === original)
        cachedVideo.close()
        assert(cachedVideo.image === image)
        results.append("videos never read the decoded image cache")

        assert(ImagePreviewState.decodedOriginals.totalCostLimit == 256 << 20)
        results.append("shared decoded image cache has a 256 MiB cost limit")

        let fetching = ImagePreviewState(thumbnail: image, id: "a", decoded: decoded)
        resume = nil
        let fetchingTask = Task {
            await fetching.load(open: {
                assert(!fetching.loading)
                return await withCheckedContinuation { resume = $0 }
            }, release: { cachedReleases += 1 })
        }
        while resume == nil { await Task.yield() }
        await fetching.load(open: { assertionFailure("duplicate open"); return file }, release: {})
        resume!.resume(returning: file)
        await fetchingTask.value
        assert(fetching.file == file && fetching.image === original)
        fetching.close()
        assert(cachedReleases == 2)
        results.append("cache hit prevents reentrant loading while opening the file")

        let activating = ImagePreviewState(thumbnail: nil, id: "a", decoded: decoded)
        activating.close()
        activating.activate()
        assert(activating.image === original && !activating.loading && activating.file == nil)
        var activationResume: CheckedContinuation<URL, Never>?
        var openedSharp = false
        let activationTask = Task {
            await activating.load(open: {
                openedSharp = activating.image === original && !activating.loading
                return await withCheckedContinuation { activationResume = $0 }
            }, release: {})
        }
        while activationResume == nil { await Task.yield() }
        assert(openedSharp && activating.image === original && !activating.loading)
        activationResume!.resume(returning: file)
        await activationTask.value
        assert(activating.file == file)
        activating.close()
        activating.activate()
        await activating.load(open: {
            assert(activating.image === original && !activating.loading)
            throw CocoaError(.fileReadNoSuchFile)
        }, release: { assertionFailure("failed open must not release") })
        assert(activating.image === original && activating.file == nil && activating.error != nil && !activating.loading)
        results.append("activation synchronously restores sharp image before open and preserves it on failure")

        let lifetimeCache = NSCache<NSString, UIImage>()
        let lifetime = ImagePreviewState(thumbnail: image, id: "lifetime", decoded: lifetimeCache)
        await lifetime.load(open: { file }, release: {})
        weak var heldDecode: UIImage?
        heldDecode = lifetime.image
        await reopened.load(open: { file }, release: {})
        let closedZoom = ZoomingImageView()
        closedZoom.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        closedZoom.setImage(reopened.image!)
        closedZoom.layoutIfNeeded()
        closedZoom.setZoomScale(2, animated: false)
        assert(closedZoom.zoomScale == 2)
        lifetime.close()
        results.append(lifetime.image === image && lifetimeCache.object(forKey: "lifetime") != nil
            ? "close restores thumbnail while original stays cached" : "FAIL: close restores thumbnail while original stays cached")
        reopened.close()
        closedZoom.setImage(reopened.image!)
        results.append(closedZoom.zoomScale == 1
            ? "close resets real image view zoom" : "FAIL: close resets real image view zoom")
        closedZoom.setImage(image)
        lifetimeCache.removeAllObjects()
        await Task.yield()
        results.append(heldDecode == nil
            ? "closed state releases evicted decode" : "FAIL: closed state releases evicted decode")

        let costCache = NSCache<NSString, UIImage>()
        let costFirst = ImagePreviewState(thumbnail: nil, id: "cost-first", decoded: costCache)
        await costFirst.load(open: { file }, release: {})
        let costImage = costFirst.image!.cgImage!
        costCache.totalCostLimit = costImage.bytesPerRow * costImage.height * 3 / 2
        costFirst.close()
        let costSecond = ImagePreviewState(thumbnail: nil, id: "cost-second", decoded: costCache)
        await costSecond.load(open: { file }, release: {})
        let firstEvicted = costCache.object(forKey: "cost-first") == nil
        costSecond.close()
        results.append(firstEvicted
            ? "decode costs evict first image when two exceed the cache limit" : "FAIL: decode costs evict first image when two exceed the cache limit")

        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
        try! JSONSerialization.data(withJSONObject: results).write(to: output)
    }
}
