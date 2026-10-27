import SwiftUI

struct NoticeView: View {
    let message: String
    let onShow: () -> Void
    let onDismiss: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.plex(.sans, 14, relativeTo: .callout))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onShow) {
                Text("Show")
                    .font(.plex(.sansSemibold, 14, relativeTo: .callout))
                    .underline()
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(palette.surface)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(palette.ink, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .task(id: "\(scenePhase == .active)\(message)") {
            guard scenePhase == .active else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            onDismiss()
        }
    }
}
