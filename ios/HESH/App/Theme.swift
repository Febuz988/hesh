import SwiftUI

/// Dark Matter / Liquid Daylight + HESH Originals. Nessuna emoji, nessuna icona
/// che non sia SF Symbols.
@Observable
@MainActor
final class Theme {
    enum Mode: String, CaseIterable { case darkMatter, liquidDaylight, system
        var colorScheme: ColorScheme? {
            switch self { case .darkMatter: .dark; case .liquidDaylight: .light; case .system: nil }
        }
        var label: String {
            switch self { case .darkMatter: "Dark Matter"; case .liquidDaylight: "Liquid Daylight"; case .system: "Segui il sistema" }
        }
    }

    enum Original: String, CaseIterable, Identifiable {
        case acid, ultraviolet, ice, rose
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .acid: Color(red: 0.78, green: 1.0, blue: 0.30)
            case .ultraviolet: Color(red: 0.62, green: 0.36, blue: 1.0)
            case .ice: Color(red: 0.31, green: 0.95, blue: 1.0)
            case .rose: Color(red: 1.0, green: 0.31, blue: 0.55)
            }
        }
        var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "theme.mode") }
    }
    var original: Original {
        didSet { UserDefaults.standard.set(original.rawValue, forKey: "theme.original") }
    }
    var reduceGlass: Bool = false

    init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "theme.mode") ?? "") ?? .darkMatter
        original = Original(rawValue: UserDefaults.standard.string(forKey: "theme.original") ?? "") ?? .acid
        reduceGlass = UIAccessibility.isReduceTransparencyEnabled
    }

    var accent: Color { original.color }
    static let danger = Color(red: 1.0, green: 0.31, blue: 0.43)
}

// MARK: Palette

extension Color {
    static let heshInk = Color(red: 0.03, green: 0.04, blue: 0.06)
    static let heshPaper = Color(red: 0.93, green: 0.95, blue: 0.97)
    static func heshText(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(red: 0.95, green: 0.96, blue: 0.98) : Color(red: 0.06, green: 0.08, blue: 0.13) }
    static func heshMuted(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(red: 0.60, green: 0.65, blue: 0.72) : Color(red: 0.29, green: 0.34, blue: 0.41) }
}

// MARK: Vetro

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Theme.self) private var theme
    var radius: CGFloat = 24
    var glow: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(theme.reduceGlass ? 0 : 1))
                    .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.65)))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    }
                    .shadow(color: glow?.opacity(0.45) ?? .clear, radius: 24)
            }
    }
}

struct HESHBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Theme.self) private var theme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color.heshInk : Color.heshPaper).ignoresSafeArea()
            if !theme.reduceGlass {
                RadialGradient(colors: [theme.accent.opacity(scheme == .dark ? 0.18 : 0.30), .clear], center: .topLeading, startRadius: 0, endRadius: 500)
                    .ignoresSafeArea()
                RadialGradient(colors: [Theme.Original.ultraviolet.color.opacity(scheme == .dark ? 0.18 : 0.22), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 480)
                    .ignoresSafeArea()
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    @Environment(Theme.self) private var theme
    var filled = true
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(filled ? Color.heshInk : (danger ? Theme.danger : .primary))
            .background {
                Capsule().fill(filled ? (danger ? Theme.danger : theme.accent) : Color.primary.opacity(0.08))
                if !filled { Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1) }
            }
            .shadow(color: filled && !danger ? theme.accent.opacity(0.5) : .clear, radius: 18)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct SectionLabel: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Color.heshMuted(scheme))
    }
}
