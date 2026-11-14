import NoteBankKit
import SwiftUI

struct SearchResultRow: View {
    let result: SearchItem
    let onOpen: () -> Void
    @Environment(\.palette) private var palette

    private var place: String { result.item.placeName ?? "" }

    private var time: String {
        let date = result.item.date
        let day = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return day + " · " + date.formatted(date: .omitted, time: .shortened)
    }

    private func highlighted(_ marked: String, links: Bool) -> AttributedString {
        let (plain, ranges) = searchMarks(marked)
        var text = links ? linkified(plain) : AttributedString(plain)
        let source = plain.unicodeScalars
        let target = text.unicodeScalars
        for range in ranges {
            let start = target.index(target.startIndex, offsetBy: source.distance(from: source.startIndex, to: range.lowerBound))
            let end = target.index(start, offsetBy: source.distance(from: range.lowerBound, to: range.upperBound))
            text[start..<end].backgroundColor = palette.accentSoft
        }
        return text
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                if let marked = result.markedText {
                    Text(highlighted(marked, links: true))
                        .font(.plex(.serif, 17))
                        .lineSpacing(3)
                        .foregroundStyle(palette.ink)
                }
                ForEach(Array(zip(result.item.attachments, result.markedFilenames)), id: \.0.id) { attachment, name in
                    HStack(spacing: 6) {
                        Text(highlighted(name, links: false)).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file))
                            .font(.plex(.mono, 12, relativeTo: .caption))
                            .foregroundStyle(palette.inkMuted)
                    }
                    .font(.plex(.sans, 14, relativeTo: .callout))
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(palette.chip, in: RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: 8) {
                    Text(place).frame(maxWidth: .infinity, alignment: .leading)
                    Text(time).font(.plex(.mono, 13, relativeTo: .footnote))
                }
                .font(.plex(.sans, 13, relativeTo: .footnote))
                .foregroundStyle(palette.inkMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.openURL, OpenURLAction { _ in onOpen(); return .handled })
        .accessibilityLabel("\(result.item.text ?? result.item.attachmentNames.first ?? ""), \(place), \(result.item.date.formatted(date: .long, time: .shortened))")
    }
}
