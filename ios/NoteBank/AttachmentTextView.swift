import UIKit
import UniformTypeIdentifiers

final class AttachmentTextView: UITextView, UITextPasteDelegate {
    var onAttachment: ((NSItemProvider, UTType) -> Void)?
    let placeholderLabel = UILabel()
    var placeholder: String = "" { didSet { placeholderLabel.text = placeholder } }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        allowsEditingTextAttributes = false
        pasteDelegate = self
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.data.identifier])
        backgroundColor = .clear
        self.textContainer.lineFragmentPadding = 0
        textContainerInset = .zero
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.isHidden = !text.isEmpty
        placeholderLabel.font = font
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        placeholderLabel.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top, width: width,
                                       height: placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    static func attachmentType(_ provider: NSItemProvider) -> UTType? {
        let types = provider.registeredContentTypes
        let images = types.filter { $0.conforms(to: .image) }
        if let image = images.first(where: { $0 != .png && $0 != .tiff }) ?? images.first { return image }
        return types.first {
            $0.conforms(to: .pdf) || $0.conforms(to: .audio) || $0.conforms(to: .movie) || $0.conforms(to: .archive) ||
            (provider.suggestedName != nil && $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) && $0 != .rtfd && $0 != .flatRTFD)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let board = UIPasteboard.general
            if board.hasImages || board.contains(pasteboardTypes: [UTType.pdf.identifier, UTType.audio.identifier, UTType.movie.identifier, UTType.archive.identifier]) {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting, transform item: any UITextPasteItem) {
        guard let type = Self.attachmentType(item.itemProvider), let onAttachment else {
            item.setDefaultResult()
            return
        }
        onAttachment(item.itemProvider, type)
        item.setNoResult()
    }
}
