import NoteBankKit
import SwiftUI

struct PlacesView: View {
    let places: Places
    let composer: ComposerModel
    let status: SyncStatus
    let notices: NoticeCenter
    let onShow: (String) -> Void
    let openSettings: () -> Void
    @Environment(\.palette) private var palette

    private func row(_ place: Place, _ name: String, _ count: Int) -> some View {
        NavigationLink(value: place) {
            HStack(spacing: 12) {
                Text(name).font(.plex(.sans, 17)).foregroundStyle(palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                Text(count, format: .number).font(.plex(.mono, 13, relativeTo: .footnote)).foregroundStyle(palette.inkMuted)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.lineStrong)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.system(size: 20)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 8)
            Text("NoteBank")
                .font(.plex(.sansSemibold, 32, relativeTo: .largeTitle))
                .kerning(-0.32)
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(spacing: 0) {
                    HomeComposerView(model: composer, topics: places.topics).padding(.bottom, 20)
                    VStack(spacing: 0) {
                        row(.all, "All Items", places.allCount)
                        Divider().overlay(palette.line)
                        row(.inbox, "Inbox", places.inboxCount)
                        Divider().overlay(palette.line)
                        row(.tunnel, "Tunnel", places.tunnelCount)
                    }
                    .card()
                    if !places.topics.isEmpty {
                        Text("Topics")
                            .textCase(.uppercase)
                            .kerning(0.96)
                            .font(.plex(.sansSemibold, 12, relativeTo: .caption))
                            .foregroundStyle(palette.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(places.topics) { topic in
                                if topic.id != places.topics.first?.id { Divider().overlay(palette.line) }
                                row(.topic(topic.id), topic.name, topic.count)
                            }
                        }
                        .card()
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            let line = SyncStatusLine(status: status, size: 13).frame(minHeight: 44)
            VStack(spacing: 0) {
                if let notice = notices.current {
                    NoticeView(message: notice.message, actionTitle: "Show", onAction: { onShow(notice.itemID) }, onDismiss: notices.dismiss)
                        .padding(.horizontal, 12)
                }
                if status.needsSettings {
                    Button(action: openSettings) { line.frame(maxWidth: .infinity).contentShape(Rectangle()) }.buttonStyle(.plain)
                } else {
                    line
                }
            }
        }
        .background(palette.surfaceSidebar)
    }
}
