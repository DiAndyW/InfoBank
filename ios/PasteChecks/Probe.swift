import UIKit
import UniformTypeIdentifiers
import SwiftUI
import Observation

@MainActor @Observable final class Draft { var text = ""; var attachments = 0 }
struct InputForm: View {
    @Bindable var draft: Draft
    let minimumLines: Int
    var body: some View {
        VStack {
            ComposerInput(text: $draft.text, placeholder: "Capture something…", minimumLines: minimumLines, lineSpacing: 3) { _, _ in draft.attachments += 1 }
            Text("Attachments: \(draft.attachments)")
        }.padding().background(Theme.paper.palette.surface)
    }
}

@MainActor func findInput(_ view: UIView) -> AttachmentTextView? {
    if let input = view as? AttachmentTextView { return input }
    return view.subviews.compactMap(findInput).first
}

@main @MainActor final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        Task { try await Task.sleep(for: .seconds(1)); await check() }
        return true
    }
    func check() async {
        let board = UIPasteboard.general
        var output: [[String: Any]] = []
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        let fixture = FileManager.default.temporaryDirectory.appending(path: "paste-check.jpg")
        try! image.jpegData(compressionQuality: 1)!.write(to: fixture)
        for (count, caption) in [(0, "Test" as String?), (1, "Test"), (3, "Test"), (1, nil), (3, nil)] {
            let providers = try! ItemClipboard.providers(text: caption, attachments: Array(repeating: (file: fixture, mimeType: "image/jpeg"), count: count))
            let previous = board.changeCount
            board.setItemProviders(providers, localOnly: false, expirationDate: Date().addingTimeInterval(60))
            let completeWrite = board.changeCount != previous && board.numberOfItems == providers.count
            let view = AttachmentTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), textContainer: nil)
            var received: [String] = []
            var receivedNames: [String] = []
            view.onAttachment = { provider, type in
                received.append(type.identifier)
                receivedNames.append(provider.suggestedName ?? "")
            }
            view.text = "before AFTER after"
            window!.rootViewController!.view.addSubview(view)
            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: 7, length: 5)
            let canPaste = view.canPerformAction(#selector(view.paste(_:)), withSender: nil)
            view.paste(nil)
            try? await Task.sleep(for: .seconds(1))
            let text = view.text ?? ""
            var embedded = 0
            view.attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.attributedText.length)) { value, _, _ in if value != nil { embedded += 1 } }
            var undoRestored = true
            if caption != nil {
                view.undoManager?.undo()
                undoRestored = view.text == "before AFTER after"
            }
            output.append(["count": count, "caption": caption ?? "", "text": text, "received": received, "receivedNames": receivedNames, "completeWrite": completeWrite, "embedded": embedded, "canPaste": canPaste, "undoRestored": undoRestored])
            view.removeFromSuperview()
        }
        for minimumLines in [1, 4] {
        let draft = Draft()
        let controller = UIHostingController(rootView: InputForm(draft: draft, minimumLines: minimumLines))
        window!.rootViewController = controller
        try? await Task.sleep(for: .milliseconds(500))
        if let view = findInput(controller.view) {
            board.setItemProviders(try! ItemClipboard.providers(text: "Bound caption", attachments: Array(repeating: (file: fixture, mimeType: "image/jpeg"), count: 3)), localOnly: false, expirationDate: Date().addingTimeInterval(60))
            view.becomeFirstResponder()
            view.paste(nil)
            try? await Task.sleep(for: .seconds(1))
            let bound = draft.text == "Bound caption" && draft.attachments == 3
            draft.text = Array(repeating: "line", count: 10).joined(separator: "\n")
            try? await Task.sleep(for: .milliseconds(300))
            let growsAndScrolls = view.isScrollEnabled && view.bounds.height <= ((view.font?.lineHeight ?? 22) + 3) * 6 + 1
            draft.text = ""
            try? await Task.sleep(for: .milliseconds(300))
            output.append(["swiftUIBinding": bound, "clearedAfterSend": view.text.isEmpty, "height": view.bounds.height, "growsAndScrolls": growsAndScrolls, "placeholderVisible": !view.placeholderLabel.isHidden, "minimumLines": minimumLines])
        } else { output.append(["swiftUIBinding": false]) }
        }
        let result = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try! result.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "result.json"))
    }
}
