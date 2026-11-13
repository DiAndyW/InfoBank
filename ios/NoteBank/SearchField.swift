import SwiftUI

private final class FocusingField: UITextField {
    var autofocus = true
    private var focusedOnce = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard autofocus, window != nil, !focusedOnce else { return }
        focusedOnce = true
        becomeFirstResponder()
    }
}

struct SearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var autofocus = true
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = FocusingField()
        field.autofocus = autofocus
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.adjustsFontForContentSizeCategory = true
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: PlexFont.sans.rawValue, size: 17) ?? .systemFont(ofSize: 17))
        field.accessibilityLabel = "Search"
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Setting text mid-composition would cancel the IME's marked text.
        if field.markedTextRange == nil && field.text != text { field.text = text }
        if focused && !field.isFirstResponder && field.window != nil { field.becomeFirstResponder() }
        if !focused && field.isFirstResponder { field.resignFirstResponder() }
        let ink = UIColor(palette.ink)
        if field.textColor != ink {
            field.textColor = ink
            field.tintColor = UIColor(palette.accent)
            field.attributedPlaceholder = NSAttributedString(string: "Search", attributes: [.foregroundColor: UIColor(palette.inkMuted), .font: field.font as Any])
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            if field.markedTextRange == nil { parent.text = field.text ?? "" }
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.focused { parent.focused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.focused { parent.focused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
        }
    }
}
