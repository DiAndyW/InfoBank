import NoteBankKit
import SwiftUI

let feedHorizontalGutter: CGFloat = 16

private struct WholeLineLayout: Layout {
    let line: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: wholeLines(size.height, line: line))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct LineSnap: ViewModifier {
    var drawsRules = false
    @Environment(\.ruledLine) private var line

    func body(content: Content) -> some View {
        if let line {
            WholeLineLayout(line: line) { content }
                .background {
                    if drawsRules { RuledPaper() }
                }
        } else {
            content
        }
    }
}

struct RuledPaper: View {
    @Environment(\.ruledLine) private var line
    @Environment(\.palette) private var palette

    var body: some View {
        if let line, let rule = palette.rule {
            Canvas { context, size in
                var path = Path()
                let bands = Int((size.height / line).rounded(.down))
                for band in 0..<bands {
                    let y = CGFloat(band + 1) * line - 0.5
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(rule), lineWidth: 1)
            }
            .padding(.horizontal, -feedHorizontalGutter)
        }
    }
}

struct FeedSectionHeader: View {
    let title: String
    @Environment(\.palette) private var palette
    @Environment(\.ruledLine) private var line

    var body: some View {
        HStack(spacing: 10) {
            if line == nil { Rectangle().fill(palette.line).frame(height: 1) }
            Text(title).font(.plex(.sansSemibold, 12, relativeTo: .caption)).foregroundStyle(palette.inkMuted)
                .ruledTextSpacing(.sansSemibold, 12, relativeTo: .caption1)
            if line == nil { Rectangle().fill(palette.line).frame(height: 1) }
        }
        .frame(maxWidth: line == nil ? nil : .infinity)
        .padding(.top, line == nil ? 14 : 0)
        .padding(.bottom, line == nil ? 6 : 0)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    func snapToLines() -> some View { modifier(LineSnap()) }
    func ruledLines() -> some View { modifier(LineSnap(drawsRules: true)) }
}

private struct RuledTextSpacing: ViewModifier {
    let font: PlexFont
    let size: CGFloat
    let style: UIFont.TextStyle
    var padsTop: Bool
    var unruledSpacing: CGFloat?
    @Environment(\.ruledLine) private var line
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if let line {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
            let size = UIFontMetrics(forTextStyle: style).scaledValue(for: size, compatibleWith: traits)
            let spacing = line - UIFont(name: font.rawValue, size: size)!.lineHeight
            content.lineSpacing(spacing).padding(.top, padsTop ? spacing / 2 : 0)
        } else if let unruledSpacing {
            content.lineSpacing(unruledSpacing)
        } else {
            content
        }
    }
}

extension View {
    func ruledTextSpacing(_ font: PlexFont, _ size: CGFloat, relativeTo style: UIFont.TextStyle, padsTop: Bool = true, unruledSpacing: CGFloat? = nil) -> some View {
        modifier(RuledTextSpacing(font: font, size: size, style: style, padsTop: padsTop, unruledSpacing: unruledSpacing))
    }
}
