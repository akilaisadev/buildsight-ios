import Foundation

/// WCAG relative-luminance contrast, so colour choices are checked by tests
/// instead of by eye.
public enum ColorContrast {
    public static func luminance(hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(hex: a), luminance(hex: b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// Foreground/background pairs used for text. Hex values live here (not in the
/// SwiftUI layer) so the contrast tests cover exactly what the app renders.
public enum DesignTokens {
    public struct Pair: Sendable { public let name: String; public let foreground: UInt32; public let background: UInt32 }

    public static let accent: UInt32 = 0xFF5A00          // brand orange; used for fills, icons and large shapes
    public static let background: UInt32 = 0xF2F2F7
    public static let surface: UInt32 = 0xFFFFFF
    public static let text: UInt32 = 0x1C1C1E
    public static let secondaryText: UInt32 = 0x3A3A3C
    /// Brand orange darkened until it reads as TEXT on white (plain #FF5A00 does not).
    public static let accentText: UInt32 = 0xC2410C
    /// Label colour on top of an orange fill. White on #FF5A00 is only ~3:1.
    public static let onAccent: UInt32 = 0x1C1C1E

    public static let statusPairs: [Pair] = [
        Pair(name: "critical", foreground: 0xB91C1C, background: 0xFEE2E2),
        Pair(name: "high", foreground: 0xA33A0A, background: 0xFFEDD5),
        Pair(name: "medium", foreground: 0x92400E, background: 0xFEF3C7),
        Pair(name: "low", foreground: 0x3F3F46, background: 0xE4E4E7),
        Pair(name: "info", foreground: 0x1D4ED8, background: 0xDBEAFE),
        Pair(name: "success", foreground: 0x166534, background: 0xDCFCE7),
    ]

    // MARK: Dark appearance. Same roles, checked against the same 4.5:1 rule.
    public static let darkBackground: UInt32 = 0x000000
    public static let darkSurface: UInt32 = 0x1C1C1E
    public static let darkText: UInt32 = 0xFFFFFF
    public static let darkSecondaryText: UInt32 = 0xAEAEB2
    public static let darkAccentText: UInt32 = 0xFF8A4C

    public static let darkStatusPairs: [Pair] = [
        Pair(name: "critical", foreground: 0xFCA5A5, background: 0x3B1111),
        Pair(name: "high", foreground: 0xFDBA74, background: 0x3B1D0A),
        Pair(name: "medium", foreground: 0xFCD34D, background: 0x3B2A05),
        Pair(name: "low", foreground: 0xD4D4D8, background: 0x2C2C2E),
        Pair(name: "info", foreground: 0x93C5FD, background: 0x0F2547),
        Pair(name: "success", foreground: 0x86EFAC, background: 0x0F2E1A),
    ]

    public static let darkTextPairs: [Pair] = [
        Pair(name: "dark text on background", foreground: darkText, background: darkBackground),
        Pair(name: "dark text on surface", foreground: darkText, background: darkSurface),
        Pair(name: "dark secondary on background", foreground: darkSecondaryText, background: darkBackground),
        Pair(name: "dark secondary on surface", foreground: darkSecondaryText, background: darkSurface),
        Pair(name: "dark accent text on surface", foreground: darkAccentText, background: darkSurface),
        Pair(name: "dark accent text on background", foreground: darkAccentText, background: darkBackground),
        Pair(name: "dark label on accent fill", foreground: onAccent, background: accent),
    ] + darkStatusPairs.map { Pair(name: "dark " + $0.name, foreground: $0.foreground, background: $0.background) }

    public static let textPairs: [Pair] = [
        Pair(name: "text on background", foreground: text, background: background),
        Pair(name: "text on surface", foreground: text, background: surface),
        Pair(name: "secondary on background", foreground: secondaryText, background: background),
        Pair(name: "secondary on surface", foreground: secondaryText, background: surface),
        Pair(name: "accent text on surface", foreground: accentText, background: surface),
        Pair(name: "accent text on background", foreground: accentText, background: background),
        Pair(name: "label on accent fill", foreground: onAccent, background: accent),
    ] + statusPairs
}
