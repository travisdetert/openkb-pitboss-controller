import SwiftUI

/// The app's colour tokens.
///
/// Every colour in the UI comes from here — no literals in views. That is what
/// makes a second theme a different set of values rather than a rewrite, and it
/// is the same rule the desktop app's stylesheet follows.
///
/// Both themes are checked against WCAG AA (4.5:1) for body text on their own
/// background; the status colours are used for fills and large type, never for
/// small text on a coloured ground.
struct Theme {
    let background: Color
    let surface: Color
    let surfaceRaised: Color
    let border: Color

    let text: Color
    let textMuted: Color

    let accent: Color
    let flame: Color      // the grill is running
    let green: Color      // at target / healthy
    let amber: Color      // warming, attention
    let red: Color        // error, over temperature
    let inactive: Color   // component idle

    static let dark = Theme(
        background:    Color(hex: 0x121316),
        surface:       Color(hex: 0x1C1E23),
        surfaceRaised: Color(hex: 0x24272E),
        border:        Color(hex: 0x343841),
        text:          Color(hex: 0xF2F3F5),
        textMuted:     Color(hex: 0x9BA1AD),
        accent:        Color(hex: 0x5EA9FF),
        flame:         Color(hex: 0xFF8A3D),
        green:         Color(hex: 0x4ADE80),
        amber:         Color(hex: 0xFBBF24),
        red:           Color(hex: 0xF87171),
        inactive:      Color(hex: 0x4A4F59)
    )

    static let light = Theme(
        background:    Color(hex: 0xF6F7F9),
        surface:       Color(hex: 0xFFFFFF),
        surfaceRaised: Color(hex: 0xEDEFF3),
        border:        Color(hex: 0xD3D7DE),
        text:          Color(hex: 0x16181D),
        textMuted:     Color(hex: 0x5A6170),
        accent:        Color(hex: 0x0B63CE),
        flame:         Color(hex: 0xBE3F0B),
        green:         Color(hex: 0x147A3A),
        amber:         Color(hex: 0x985D06),
        red:           Color(hex: 0xB91C1C),
        inactive:      Color(hex: 0xA8AEB9)
    )
}

/// What the user chose, which is not the same as what is showing.
///
/// The OS preference is the default and the toggle overrides it — the toggle
/// wins, the OS is the fallback. Persisted so the choice survives a relaunch.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// nil means "follow the OS".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
