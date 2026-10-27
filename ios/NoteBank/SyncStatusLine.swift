import NoteBankKit
import SwiftUI

extension SyncStatus {
    var needsSettings: Bool { self == .unauthorized || self == .keychain }
}

struct SyncStatusLine: View {
    let status: SyncStatus
    var size: CGFloat = 12
    @Environment(\.palette) private var palette

    var body: some View {
        if status != .notConfigured {
            HStack(spacing: 5) {
                switch status {
                case .synced: Circle().fill(palette.okMark).frame(width: 7, height: 7)
                case .syncing: Image(systemName: "arrow.triangle.2.circlepath")
                case .offline: Circle().strokeBorder(palette.inkMuted, lineWidth: 1.5).frame(width: 7, height: 7)
                case .unauthorized, .keychain: Image(systemName: "exclamationmark.triangle")
                case .notConfigured: EmptyView()
                }
                Text(status.label)
            }
            .font(.plex(status.needsSettings ? .sansSemibold : .sansMedium, size, relativeTo: .caption))
            .foregroundStyle(status.needsSettings ? palette.danger : palette.inkMuted)
        }
    }
}
