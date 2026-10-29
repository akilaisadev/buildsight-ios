import SwiftUI
import BuildSightKit
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that follows the system appearance (Light / Dark), including the
    /// in-app switch. Both values come from `DesignTokens`, where contrast is tested.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
        #else
        self.init(hex: light)
        #endif
    }
}

/// Colours come from `DesignTokens` in the package, where contrast is tested for
/// both appearances. Screens use these roles, never raw hex values.
enum Theme {
    static let accent = Color(hex: DesignTokens.accent)                                   // brand orange: fills and icons
    static let onAccent = Color(hex: DesignTokens.onAccent)                               // label on an orange fill
    static let accentText = Color(light: DesignTokens.accentText, dark: DesignTokens.darkAccentText)
    static let background = Color(light: DesignTokens.background, dark: DesignTokens.darkBackground)   // grouped background
    static let surface = Color(light: DesignTokens.surface, dark: DesignTokens.darkSurface)            // rows and cards
    static let text = Color(light: DesignTokens.text, dark: DesignTokens.darkText)
    static let secondaryText = Color(light: DesignTokens.secondaryText, dark: DesignTokens.darkSecondaryText)
    static let cornerRadius: CGFloat = 12

    static func status(_ name: String) -> (fg: Color, bg: Color) {
        let light = DesignTokens.statusPairs.first { $0.name == name } ?? DesignTokens.statusPairs[3]
        let dark = DesignTokens.darkStatusPairs.first { $0.name == light.name } ?? DesignTokens.darkStatusPairs[3]
        return (Color(light: light.foreground, dark: dark.foreground), Color(light: light.background, dark: dark.background))
    }
}

/// A grouped block of content, like a row group in Settings: system-sized corner
/// radius, a hairline edge that stays visible in Dark Mode.
/// Appearance chosen in Settings: "system" follows the phone (Light by day, Dark at night).
enum AppearanceSetting {
    static let key = "appearance"
    static func colorScheme(_ raw: String) -> ColorScheme? {
        switch raw { case "light": .light; case "dark": .dark; default: nil }
    }
}

/// Sizes for gloved hands: every tap target is at least 64 pt (system minimum is 44 pt).
enum Glove {
    static let target: CGFloat = 64
    static let spacing: CGFloat = 16
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// Primary action. Dark label on the orange fill (white would be ~3:1).
/// Scales slightly while pressed, like system buttons.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: Glove.target)
            .background(Theme.accent.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.accentText)
            .frame(maxWidth: .infinity, minHeight: Glove.target)
            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
