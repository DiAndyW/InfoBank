import SwiftUI

struct Palette {
    let surface, surfaceSidebar, surfaceRaised, hover, line, lineStrong, ink, inkMuted: Color
    let accent, onAccent, accentSoft, okMark, danger, dangerSoft, chip: Color
}

enum Theme: String, CaseIterable {
    case paper, blackboard, notepad

    @MainActor static let store = UserDefaults(suiteName: "group.app.notebank")

    var title: String {
        switch self {
        case .paper: "Warm paper"
        case .blackboard: "Blackboard"
        case .notepad: "Notepad"
        }
    }

    var colorScheme: ColorScheme { self == .blackboard ? .dark : .light }

    var palette: Palette {
        switch self {
        case .paper:
            Palette(
                surface: Color(0xf6f1e7), surfaceSidebar: Color(0xede6d8), surfaceRaised: Color(0xfffcf6), hover: Color(0xe5ddcc),
                line: Color(0xddd3c2), lineStrong: Color(0x8c8070), ink: Color(0x2a241c), inkMuted: Color(0x665b4d),
                accent: Color(0x1f4e79), onAccent: Color(0xfffcf6), accentSoft: Color(0xdde5ee),
                okMark: Color(0x2f8f52), danger: Color(0xa3301d), dangerSoft: Color(0xf4dcd4), chip: Color(0xe8e0cf))
        case .blackboard:
            Palette(
                surface: Color(0x1e2522), surfaceSidebar: Color(0x171d1a), surfaceRaised: Color(0x2a322e), hover: Color(0x34403a),
                line: Color(0x34403a), lineStrong: Color(0x76877d), ink: Color(0xecefe6), inkMuted: Color(0xa9b3aa),
                accent: Color(0xe8cf74), onAccent: Color(0x1e2522), accentSoft: Color(0x38382a),
                okMark: Color(0x9fd3a8), danger: Color(0xff9b87), dangerSoft: Color(0x46291f), chip: Color(0x2f3934))
        case .notepad:
            Palette(
                surface: Color(0xfdf5b8), surfaceSidebar: Color(0xefe2a0), surfaceRaised: Color(0xfffbe0), hover: Color(0xebdc95),
                line: Color(0xd8c879), lineStrong: Color(0x8a7f4c), ink: Color(0x1f2a44), inkMuted: Color(0x5c5433),
                accent: Color(0x1e4fa8), onAccent: Color(0xfffbe0), accentSoft: Color(0xe4dfb4),
                okMark: Color(0x2f8f52), danger: Color(0xa3261b), dangerSoft: Color(0xf7dcc4), chip: Color(0xf3e7a6))
        }
    }
}

extension Color {
    init(_ hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension EnvironmentValues {
    @Entry var palette = Theme.paper.palette
}

enum PlexFont: String {
    case sans = "IBMPlexSans"
    case sansMedium = "IBMPlexSans-Medm"
    case sansSemibold = "IBMPlexSans-SmBld"
    case mono = "IBMPlexMono-Medm"
    case serif = "SourceSerif4-Regular"
}

extension Font {
    static func plex(_ font: PlexFont, _ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(font.rawValue, size: size, relativeTo: style)
    }
}

struct Card: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line))
    }
}

struct ChipStyle: ViewModifier {
    let active: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .font(.plex(.sansMedium, 14, relativeTo: .callout))
            .foregroundStyle(active ? palette.onAccent : palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(active ? palette.accent : palette.chip, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

// Fills the width it's given, so the name never sizes the chip (on iOS 27 a Menu label sized by its text keeps a stale width).
struct PlaceChipLabel: View {
    let title: String
    var active = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .chipStyle(active: active)
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
    func chipStyle(active: Bool = false) -> some View { modifier(ChipStyle(active: active)) }
}
