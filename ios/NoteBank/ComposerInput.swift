import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerInput: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var minimumLines = 1
    var lineSpacing: CGFloat = 0
    let onAttachment: (NSItemProvider, UTType) -> Void
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AttachmentTextView {
        let view = AttachmentTextView(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        view.onAttachment = { [weak coordinator = context.coordinator] provider, type in
            coordinator?.parent.onAttachment(provider, type)
        }
        return view
    }

    func updateUIView(_ view: AttachmentTextView, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange == nil && view.text != text { view.text = text }
        view.placeholder = placeholder
        view.accessibilityLabel = minimumLines > 1 ? "Capture" : placeholder
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: PlexFont.serif.rawValue, size: 17) ?? UIFont.systemFont(ofSize: 17))
        let color = UIColor(palette.ink)
        view.font = font
        view.textColor = color
        view.tintColor = UIColor(palette.accent)
        view.placeholderLabel.textColor = UIColor(palette.inkMuted)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        view.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AttachmentTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let lineHeight = (uiView.font?.lineHeight ?? 22) + lineSpacing
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maximum = lineHeight * 6
        if uiView.isScrollEnabled != (height > maximum) { uiView.isScrollEnabled = height > maximum }
        return CGSize(width: width, height: min(maximum, max(lineHeight * CGFloat(minimumLines), height)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerInput
        init(_ parent: ComposerInput) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
    }
}
