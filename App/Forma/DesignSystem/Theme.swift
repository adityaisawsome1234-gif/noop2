import SwiftUI
import UIKit
import FormaFeatures

/// Forma design tokens. Colors are defined in code (not an asset catalog) so light, dark and
/// increased-contrast variants live side by side and can be reviewed together.
enum Theme {
    // MARK: Color tokens

    /// Warm off-white page background (light) / near-black graphite (dark).
    static let background = dynamic(light: 0xF6F4EF, dark: 0x141617, lightHC: 0xFBFAF7, darkHC: 0x000000)
    /// Card / grouped surface.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1D2022, lightHC: 0xFFFFFF, darkHC: 0x15181A)
    /// Slightly recessed surface for wells, segmented areas and table stripes.
    static let surfaceMuted = dynamic(light: 0xEFECE5, dark: 0x24282A, lightHC: 0xE7E3DA, darkHC: 0x23272A)
    /// Hairline borders.
    static let border = dynamic(light: 0xE2DED5, dark: 0x30353A, lightHC: 0x8F8A80, darkHC: 0x8B9196)

    /// Charcoal primary text.
    static let textPrimary = dynamic(light: 0x1F2226, dark: 0xECEDEE, lightHC: 0x000000, darkHC: 0xFFFFFF)
    /// Secondary text (≥ 4.5:1 on background in both modes).
    static let textSecondary = dynamic(light: 0x585D63, dark: 0xA9AEB3, lightHC: 0x33373B, darkHC: 0xD5D8DB)

    /// Restrained teal accent (≥ 4.5:1 on background as text).
    static let accent = dynamic(light: 0x1C6F69, dark: 0x5BBDB2, lightHC: 0x0E4F4A, darkHC: 0x8ADCD2)
    /// Text and icons drawn on an `accent` fill (primary buttons). White on the dark teal of light mode,
    /// near-black on the light teal of dark mode: ≥ 5.9:1 in all four variants (white on the dark-mode
    /// accent would be only 2.2:1).
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B1F1D, lightHC: 0xFFFFFF, darkHC: 0x0B1F1D)
    /// Low-emphasis accent fill (selected chips, live indicator halo).
    static let accentSoft = dynamic(light: 0xDDEDEA, dark: 0x1D3533, lightHC: 0xC9E3DF, darkHC: 0x204440)

    /// Attention (calibrating, partial data). Used with an icon, never color alone.
    static let caution = dynamic(light: 0x8A5A00, dark: 0xE2B45C, lightHC: 0x6A4400, darkHC: 0xF2CB7E)
    static let cautionSoft = dynamic(light: 0xF8EDD6, dark: 0x3A2F1A, lightHC: 0xF2E0BB, darkHC: 0x4A3B1E)
    /// Errors and failed checks.
    static let critical = dynamic(light: 0xA8281E, dark: 0xF08A80, lightHC: 0x7F1A12, darkHC: 0xFFB0A8)
    static let criticalSoft = dynamic(light: 0xFBE7E5, dark: 0x3D201D, lightHC: 0xF6D3CF, darkHC: 0x4E2622)
    /// Demo-data label: deliberately distinct from every data color.
    static let demo = dynamic(light: 0x5B3FA8, dark: 0xB7A4F2, lightHC: 0x3F2785, darkHC: 0xD2C6FA)
    static let demoSoft = dynamic(light: 0xECE6FA, dark: 0x2A2340, lightHC: 0xDCD2F6, darkHC: 0x352B52)

    /// Heart-rate zone ramp (zone 1 → 5): one hue family, increasing depth. Zones are always labelled
    /// with their number as well, so the ramp is never the only signal.
    static let zoneColors: [Color] = [
        dynamic(light: 0xB9DCD7, dark: 0x2C5450, lightHC: 0x9FCFC8, darkHC: 0x3B6C67),
        dynamic(light: 0x86C3BA, dark: 0x3A7A73, lightHC: 0x6BB3A9, darkHC: 0x4E918A),
        dynamic(light: 0x4FA096, dark: 0x4FA096, lightHC: 0x2F8378, darkHC: 0x66B8AE),
        dynamic(light: 0x2A7A72, dark: 0x6FC2B8, lightHC: 0x165F58, darkHC: 0x8ED6CD),
        dynamic(light: 0x174A46, dark: 0xA7E1D9, lightHC: 0x0A322F, darkHC: 0xC6EEE8),
    ]

    // MARK: Layout tokens

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    static let cornerRadius: CGFloat = 14
    static let hairline: CGFloat = 1

    // MARK: Typography (all Dynamic Type text styles; numbers use monospaced digits)

    enum Typeface {
        static let metricValue = Font.system(.title, design: .default, weight: .semibold).monospacedDigit()
        static let metricValueLarge = Font.system(.largeTitle, design: .default, weight: .semibold).monospacedDigit()
        static let metricUnit = Font.system(.body, design: .default, weight: .regular)
        static let cardTitle = Font.headline
        static let label = Font.subheadline
        static let caption = Font.footnote
    }

    // MARK: Helpers

    private static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) -> Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHC = traits.accessibilityContrast == .high
            switch (isDark, isHC) {
            case (false, false): return UIColor(hex: light)
            case (true, false): return UIColor(hex: dark)
            case (false, true): return UIColor(hex: lightHC)
            case (true, true): return UIColor(hex: darkHC)
            }
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension AppearancePreference {
    /// SwiftUI color scheme for `.preferredColorScheme` (nil = follow the system).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The same preference for UIKit windows (the App Lock window).
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}
