import AVKit
import ImageIO
import SwiftUI

@MainActor @Observable
final class ImagePreviewState {
    static let decodedOriginals: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()

    private let id: String?
    private let decoded: NSCache<NSString, UIImage>
    private var fetching = false
    private let thumbnail: UIImage?
    private let isVideo: Bool
    private var generation = UUID()
    private var releaseFile: (() -> Void)?
    var image: UIImage?
    private(set) var file: URL?
    private(set) var player: AVPlayer?
    private(set) var loading = false
    private(set) var error: String?

    init(thumbnail: UIImage?, isVideo: Bool = false, id: String? = nil,
         decoded: NSCache<NSString, UIImage> = ImagePreviewState.decodedOriginals) {
        self.thumbnail = thumbnail
        self.isVideo = isVideo
        self.id = isVideo ? nil : id
        self.decoded = decoded
        image = cachedImage ?? thumbnail
    }

    private var cachedImage: UIImage? {
        id.flatMap { decoded.object(forKey: $0 as NSString) }
    }

    func activate() {
        if let cachedImage { image = cachedImage }
    }

    func load(open: () async throws -> URL, release: @escaping () -> Void) async {
        guard !fetching, file == nil else { return }
        let current = generation
        let cached = cachedImage
        if let cached { image = cached }
        fetching = true
        loading = cached == nil
        error = nil
        defer {
            if generation == current {
                loading = false
                fetching = false
            }
        }
        do {
            let url = try await open()
            guard generation == current, !Task.isCancelled else { release(); return }
            if isVideo {
                file = url
                releaseFile = release
                player = AVPlayer(url: url)
                player?.play()
                return
            }
            if cached != nil {
                file = url
                releaseFile = release
                return
            }
            // Bound decoded memory while preserving orientation; sharing still uses the original.
            let original = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { return UIImage?.none }
                return UIImage(cgImage: image)
            }.value
            guard generation == current, !Task.isCancelled else { release(); return }
            guard let original else {
                release()
                error = "This image couldn't be displayed."
                return
            }
            if let id, let cgImage = original.cgImage {
                decoded.setObject(original, forKey: id as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            }
            image = original
            file = url
            releaseFile = release
        } catch {
            if generation == current, !Task.isCancelled { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't load this \(isVideo ? "video" : "image"). Try again." }
        }
    }

    func close() {
        generation = UUID()
        player?.pause()
        player = nil
        releaseFile?()
        releaseFile = nil
        file = nil
        image = thumbnail
        loading = false
        fetching = false
    }
}

struct ImagePreviewItem: Identifiable {
    let id: String
    let filename: String
    var thumbnail: UIImage?
    var isVideo = false
}

struct ImageViewer: View {
    let images: [ImagePreviewItem]
    @State var selectedID: String
    let open: (String) async throws -> URL
    let thumbnail: (String) async -> UIImage?
    let release: (String) -> Void
    @State private var files: [String: URL] = [:]
    @State private var sharing = false
    @State private var barHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let position = images.firstIndex { $0.id == selectedID } ?? 0
        let selected = images[position]
        let kind = selected.isVideo ? "video" : "image"
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            // The pager runs under the bar so a swipe that starts on the bar still pages.
            TabView(selection: $selectedID) {
                ForEach(images) { image in
                    ImagePreviewPage(item: image, active: selectedID == image.id,
                                     open: { try await open(image.id) },
                                     thumbnail: { await thumbnail(image.id) },
                                     release: { release(image.id) },
                                     onFile: { files[image.id] = $0 })
                        .padding(.top, barHeight)
                        .tag(image.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close \(kind)")
                    .keyboardShortcut(.cancelAction)
                VStack(spacing: 2) {
                    Text(selected.filename).lineLimit(1)
                    if images.count > 1 { Text("\(position + 1) of \(images.count)").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                Button { sharing = true } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share \(kind)")
                .disabled(files[selected.id] == nil)
            }
            .padding(.horizontal, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $sharing) {
            if let file = files[selectedID] { ImageShareSheet(file: file) }
        }
    }
}

private struct ImagePreviewPage: View {
    let item: ImagePreviewItem
    let active: Bool
    let open: () async throws -> URL
    let thumbnail: () async -> UIImage?
    let release: () -> Void
    let onFile: (URL?) -> Void
    @State private var state: ImagePreviewState
    @State private var retry = 0
    @State private var zoomed = false
    @State private var pullDown: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(item: ImagePreviewItem, active: Bool, open: @escaping () async throws -> URL,
         thumbnail: @escaping () async -> UIImage?, release: @escaping () -> Void, onFile: @escaping (URL?) -> Void) {
        self.item = item
        self.active = active
        self.open = open
        self.thumbnail = thumbnail
        self.release = release
        self.onFile = onFile
        _state = State(initialValue: ImagePreviewState(thumbnail: item.thumbnail, isVideo: item.isVideo, id: item.id))
    }

    var body: some View {
        ZStack {
            if let player = state.player {
                VideoPlayer(player: player)
            } else if let image = state.image {
                ZoomableImage(image: image, label: item.filename) { zoomed = $0 }
            }
            if state.loading { ProgressView().tint(.white).padding(12).background(.black.opacity(0.6), in: Capsule()) }
        }
        .offset(y: pullDown)
        .gesture(PullDownGesture(zoomed: zoomed, onChange: { pullDown = $0 }, onEnd: { distance in
            if distance > 100 { dismiss() }
            else { withAnimation(.spring) { pullDown = 0 } }
        }))
        .safeAreaInset(edge: .bottom) {
            if let error = state.error {
                VStack(spacing: 8) {
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    Button("Retry") { retry += 1 }.frame(minHeight: 44)
                }
                .padding(.horizontal)
                .background(.black)
            }
        }
        .task(id: active ? retry : -1) {
            guard active else { state.close(); return }
            state.activate()
            if state.image == nil { state.image = await thumbnail() }
            guard !Task.isCancelled else { return }
            await state.load(open: open, release: release)
        }
        .onChange(of: state.file) { onFile(state.file) }
        .onDisappear {
            state.close()
            onFile(nil)
        }
    }
}

// A SwiftUI DragGesture here blocks fast horizontal flicks; this pan refuses them so the pager gets them.
private struct PullDownGesture: UIGestureRecognizerRepresentable {
    let zoomed: Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var zoomed = false

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard !zoomed, let pan = gesture as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.zoomed = zoomed
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: nil)
        let downward = translation.y > abs(translation.x) ? translation.y : 0
        switch pan.state {
        case .changed: if downward > 0 { onChange(downward) }
        case .ended: onEnd(downward)
        case .cancelled, .failed: onEnd(0)
        default: break
        }
    }
}

private struct ImageShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let label: String
    let onZoom: (Bool) -> Void
    func makeUIView(context: Context) -> ZoomingImageView { ZoomingImageView() }
    func updateUIView(_ view: ZoomingImageView, context: Context) {
        view.onZoom = onZoom
        view.setImage(image, label: label)
    }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var lastSize = CGSize.zero
    var onZoom: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        panGestureRecognizer.isEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage, label: String? = nil) {
        imageView.accessibilityLabel = label
        guard imageView.image !== image else { return }
        setZoomScale(1, animated: false)
        imageView.image = image
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            setZoomScale(1, animated: false)
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        panGestureRecognizer.isEnabled = zoomScale > 1
        onZoom?(zoomScale > 1)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
