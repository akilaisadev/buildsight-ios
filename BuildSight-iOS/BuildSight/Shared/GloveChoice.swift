import SwiftUI

/// One option in a `GloveChoice`. `tone` picks a contrast-tested status colour
/// for the selected state (for example "success" for Pass, "critical" for Fail).
struct GloveOption<Value: Hashable> {
    let label: String
    var symbol: String? = nil
    let value: Value
    var tone: String? = nil
}

/// Glove-sized single choice: full-width buttons at least 64 pt tall, used instead
/// of the 32 pt system segmented control everywhere a worker picks one option.
struct GloveChoice<Value: Hashable>: View {
    let options: [GloveOption<Value>]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.value == selection
                let colors = Self.colors(on: on, tone: option.tone)
                Button { selection = option.value } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol { Image(systemName: symbol) }
                        Text(option.label).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(options.count > 3 ? .subheadline.weight(.semibold) : .headline)
                    .frame(maxWidth: .infinity, minHeight: Glove.target)
                    .foregroundStyle(colors.fg)
                    .background(colors.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(on ? 0 : 0.12), lineWidth: 1))
                    .opacity(enabled ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private static func colors(on: Bool, tone: String?) -> (fg: Color, bg: Color) {
        guard on else { return (Theme.text, Theme.surface) }
        if let tone { let pair = Theme.status(tone); return (pair.fg, pair.bg) }
        return (Color(light: 0xFFFFFF, dark: 0x000000), Color(light: 0x1C1C1E, dark: 0xFFFFFF))
    }
}
