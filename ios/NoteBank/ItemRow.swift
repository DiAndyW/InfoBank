import NoteBankKit
import SwiftUI

extension FeedItem {
    var date: Date { Date(timeIntervalSince1970: Double(captureTimeUs) / 1_000_000) }
}

struct ItemRow: View {
    let item: FeedItem
    let showsTopic: Bool
    let highlighted: Bool
    let copyable: Bool
    let copied: Bool
    let onCopy: () -> Void
    let onDiscard: () -> Void

    @Environment(\.palette) private var palette
    @State private var showingReason = false
    @State private var confirmingDiscard = false

    private var chipTitle: String? {
        guard showsTopic else { return nil }
        return item.topicID == nil ? "Inbox" : item.topicName
    }

    private func reasonText(_ reason: String) -> String {
        let sentence = switch reason {
        case "invalid": "The Server refused this Item as invalid."
        case "exists": "The Server already has an Item with this id."
        default: "The Server refused this Item (\(reason))."
        }
        return sentence + " It's only on this iPhone."
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for part in linkify(item.text ?? "") {
            switch part {
            case .text(let text): result += AttributedString(text)
            case .link(let text):
                var link = AttributedString(text)
                link.link = URL(string: text)
                result += link
            }
        }
        return result
    }

    @ViewBuilder private var copyButton: some View {
        if let text = item.text {
            Button("Copy Text", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if item.text != nil {
                    Text(attributedText)
                        .font(.plex(.serif, 17))
                        .lineSpacing(3)
                        .foregroundStyle(palette.ink)
                }
                ForEach(item.attachmentNames, id: \.self) { name in
                    Label(name, systemImage: "paperclip")
                        .font(.plex(.sans, 13, relativeTo: .footnote))
                        .foregroundStyle(palette.inkMuted)
                }
                if let chipTitle {
                    Text(chipTitle)
                        .font(.plex(.sansMedium, 12, relativeTo: .caption))
                        .foregroundStyle(palette.inkMuted)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .background(palette.chip, in: RoundedRectangle(cornerRadius: 4))
                }
                if let reason = item.syncError {
                    Button { showingReason = true } label: {
                        Label("Couldn't sync", systemImage: "exclamationmark.triangle")
                            .font(.plex(.sansSemibold, 12, relativeTo: .caption))
                            .foregroundStyle(palette.danger)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 20)
                            .background(palette.dangerSoft, in: RoundedRectangle(cornerRadius: 4))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingReason) {
                        Text(reasonText(reason))
                            .font(.plex(.sans, 14, relativeTo: .callout))
                            .padding()
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.plex(.sansSemibold, 12, relativeTo: .caption))
                        .foregroundStyle(palette.okMark)
                } else if item.pending {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.inkMuted)
                        .accessibilityLabel("Not synced yet")
                }
                Text(item.date.formatted(date: .omitted, time: .shortened))
                    .font(.plex(.mono, 12, relativeTo: .caption))
                    .foregroundStyle(palette.inkMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minHeight: 25)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if copyable && item.text != nil { onCopy() } }
        .background(highlighted ? palette.accentSoft : .clear)
        .environment(\.openURL, OpenURLAction { ["http", "https"].contains($0.scheme?.lowercased()) ? .systemAction : .discarded })
        .contextMenu {
            if let reason = item.syncError {
                Section(reasonText(reason)) {
                    copyButton
                    Button("Discard…", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
                }
            } else {
                copyButton
            }
        }
        .alert("Discard this Item?", isPresented: $confirmingDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive, action: onDiscard)
        } message: {
            Text("\"\(item.label)\" is only on this iPhone. Discarding deletes it here, and there's no Trash or Undo for this.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(copyable && item.text != nil ? .isButton : [])
        .accessibilityAction(named: "Copy") { if copyable && item.text != nil { onCopy() } }
    }
}
