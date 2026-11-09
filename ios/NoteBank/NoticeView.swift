import SwiftUI

struct NoticeView: View {
    let message: String
    let actionTitle: String?
    let onAction: (() -> Void)?
    let onDismiss: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(wrapping: false)
            row(wrapping: true)
        }
        .foregroundStyle(palette.surface)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(palette.ink, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .task(id: message) {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            onDismiss()
        }
    }

    private func row(wrapping: Bool) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.plex(.sans, 14, relativeTo: .callout))
                .fixedSize(horizontal: !wrapping, vertical: wrapping)
                .frame(maxWidth: wrapping ? .infinity : nil, alignment: .leading)
            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(.plex(.sansSemibold, 14, relativeTo: .callout))
                        .underline()
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                }
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss")
        }
    }
}
