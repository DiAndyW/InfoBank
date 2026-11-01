import ImageIO
import SwiftUI

@MainActor @Observable
final class ImagePreviewState {
    private let thumbnail: UIImage?
    private var generation = UUID()
    private var releaseFile: (() -> Void)?
    var image: UIImage?
    private(set) var file: URL?
    private(set) var loading = false
    private(set) var error: String?

    init(thumbnail: UIImage?) {
        self.thumbnail = thumbnail
        image = thumbnail
    }

    func load(open: () async throws -> URL, release: @escaping () -> Void) async {
        guard !loading, file == nil else { return }
        let current = generation
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            let url = try await open()
            guard generation == current, !Task.isCancelled else { release(); return }
            // Bound decoded memory while preserving orientation; sharing still uses the original.
            let decoded = await Task.detached(priority: .userInitiated) {
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
            guard let decoded else {
                release()
                error = "This image couldn't be displayed."
                return
            }
            image = decoded
            file = url
            releaseFile = release
        } catch {
            if generation == current, !Task.isCancelled { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't load this image. Try again." }
        }
    }

    func close() {
        generation = UUID()
        releaseFile?()
        releaseFile = nil
        file = nil
        image = thumbnail
        loading = false
    }
}

struct ImagePreviewItem: Identifiable {
    let id: String
    let filename: String
    var thumbnail: UIImage?
}

struct ImageViewer: View {
    let images: [ImagePreviewItem]
    @State var selectedID: String
    let open: (String) async throws -> URL
    let thumbnail: (String) async -> UIImage?
    let release: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selectedID) {
                ForEach(images) { image in
                    ImagePreviewPage(item: image, active: selectedID == image.id,
                                     position: (images.firstIndex(where: { $0.id == image.id }) ?? 0) + 1, count: images.count,
                                     open: { try await open(image.id) },
                                     thumbnail: { await thumbnail(image.id) },
                                     release: { release(image.id) })
                        .tag(image.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

private struct ImagePreviewPage: View {
    let item: ImagePreviewItem
    let active: Bool
    let position: Int
    let count: Int
    let open: () async throws -> URL
    let thumbnail: () async -> UIImage?
    let release: () -> Void
    @State private var state: ImagePreviewState
    @State private var retry = 0
    @State private var sharing = false
    @State private var zoomed = false
    @State private var pullDown: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(item: ImagePreviewItem, active: Bool, position: Int, count: Int, open: @escaping () async throws -> URL,
         thumbnail: @escaping () async -> UIImage?, release: @escaping () -> Void) {
        self.item = item
        self.active = active
        self.position = position
        self.count = count
        self.open = open
        self.thumbnail = thumbnail
        self.release = release
        _state = State(initialValue: ImagePreviewState(thumbnail: item.thumbnail))
    }

    var body: some View {
        ZStack {
            if let image = state.image {
                ZoomableImage(image: image, label: item.filename) { zoomed = $0 }
            }
            if state.loading { ProgressView().tint(.white).padding(12).background(.black.opacity(0.6), in: Capsule()) }
        }
        .offset(y: pullDown)
        .simultaneousGesture(DragGesture(minimumDistance: 20)
            .onChanged { drag in
                guard !zoomed, drag.translation.height > abs(drag.translation.width) else { return }
                pullDown = drag.translation.height
            }
            .onEnded { drag in
                if !zoomed, drag.translation.height > 100, drag.translation.height > abs(drag.translation.width) { dismiss() }
                else { withAnimation(.spring) { pullDown = 0 } }
            })
        .safeAreaInset(edge: .top) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close image")
                    .keyboardShortcut(.cancelAction)
                VStack(spacing: 2) {
                    Text(item.filename).lineLimit(1)
                    if count > 1 { Text("\(position) of \(count)").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                Button { sharing = true } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share image")
                .disabled(state.file == nil)
            }
            .padding(.horizontal, 8)
            .background(.black)
        }
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
            if state.image == nil { state.image = await thumbnail() }
            guard !Task.isCancelled else { return }
            await state.load(open: open, release: release)
        }
        .onDisappear { state.close() }
        .sheet(isPresented: $sharing) {
            if let file = state.file { ImageShareSheet(file: file) }
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
