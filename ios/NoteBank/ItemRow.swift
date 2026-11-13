import NoteBankKit
import SwiftUI

extension FeedItem {
    var placeName: String? { inTunnel ? "Tunnel" : topicID == nil ? "Inbox" : topicName }
}

func linkified(_ text: String) -> AttributedString {
    var result = AttributedString()
    for part in linkify(text) {
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

struct ItemRow: View {
    let item: FeedItem
    let showsTopic: Bool
    let highlighted: Bool
    let copyable: Bool
    let copied: Bool
    let onCopy: () -> Void
    let onCommands: () -> Void
    var inTrash = false
    var showsTime = true

    @Environment(\.palette) private var palette
    @State private var showingReason = false

    private var chipTitle: String? {
        showsTopic ? item.placeName : nil
    }

    private func reasonText(_ reason: String) -> String {
        let sentence = switch reason {
        case "invalid": "The Server refused this Item as invalid."
        case "exists": "The Server already has an Item with this id."
        default: "The Server refused this Item (\(reason))."
        }
        return sentence + " It's only on this iPhone."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let text = item.text {
                    Text(linkified(text))
                        .font(.plex(.serif, 17))
                        .lineSpacing(3)
                        .foregroundStyle(palette.ink)
                }
                ForEach(item.attachments) { attachment in
                    AttachmentView(attachment: attachment, attachments: item.attachments)
                }
                if item.conflict != nil && !inTrash {
                    Button(action: onCommands) { Label("Text conflict", systemImage: "exclamationmark.bubble") }
                        .font(.plex(.sansSemibold, 12, relativeTo: .caption))
                        .foregroundStyle(palette.danger)
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)
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

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let chipTitle {
                    Text(chipTitle)
                        .font(.plex(.sansMedium, 12, relativeTo: .caption))
                        .foregroundStyle(palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.chip, in: RoundedRectangle(cornerRadius: 4))
                }
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
                if !inTrash {
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                        .font(.plex(.mono, 12, relativeTo: .caption))
                        // Clear, not hidden, so the row keeps its width and VoiceOver still reads the time.
                        .foregroundStyle(showsTime ? palette.inkMuted : .clear)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            }
            .frame(minHeight: 25, alignment: .trailing)
            .layoutPriority(1)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if copyable { onCopy() }
            else { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .background(highlighted ? palette.accentSoft : .clear)
        .environment(\.openURL, OpenURLAction { ["http", "https"].contains($0.scheme?.lowercased()) ? .systemAction : .discarded })
        .accessibilityElement(children: item.attachments.isEmpty ? .combine : .contain)
        .accessibilityAddTraits(copyable ? .isButton : [])
        .accessibilityAction(named: "Item actions", onCommands)
        .accessibilityActions {
            if copyable {
                Button(CopyActions.copyLabel, action: onCopy)
            }
        }
    }
}
