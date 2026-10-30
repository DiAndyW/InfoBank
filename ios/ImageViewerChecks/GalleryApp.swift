import SwiftUI

@main
struct GalleryChecksApp: App {
    var body: some Scene { WindowGroup { GalleryFixture() } }
}

struct GalleryFixture: View {
    @State private var showing = false
    @State private var failedOnce = false
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
    }
}
