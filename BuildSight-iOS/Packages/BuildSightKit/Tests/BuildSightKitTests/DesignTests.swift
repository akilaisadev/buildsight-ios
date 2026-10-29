import Testing
@testable import BuildSightKit

@Suite("Contrast")
struct ContrastTests {
    @Test("Known reference values")
    func reference() {
        #expect(abs(ColorContrast.ratio(0x000000, 0xFFFFFF) - 21) < 0.01)
        #expect(abs(ColorContrast.ratio(0x777777, 0xFFFFFF) - 4.48) < 0.05)
    }

    @Test("Every text pair in the design tokens meets WCAG AA (4.5:1)", arguments: DesignTokens.textPairs.map(\.name))
    func textPairsPass(name: String) throws {
        let pair = try #require(DesignTokens.textPairs.first { $0.name == name })
        let ratio = ColorContrast.ratio(pair.foreground, pair.background)
        #expect(ratio >= 4.5, "\(name) is only \(ratio):1")
    }

    @Test("Every dark-appearance text pair also meets WCAG AA (4.5:1)", arguments: DesignTokens.darkTextPairs.map(\.name))
    func darkTextPairsPass(name: String) throws {
        let pair = try #require(DesignTokens.darkTextPairs.first { $0.name == name })
        let ratio = ColorContrast.ratio(pair.foreground, pair.background)
        #expect(ratio >= 4.5, "\(name) is only \(ratio):1")
    }

    @Test("Light and dark status tokens cover the same set of names")
    func statusNamesMatch() {
        #expect(DesignTokens.statusPairs.map(\.name) == DesignTokens.darkStatusPairs.map(\.name))
    }

    @Test("The prototype's white-on-orange combination does NOT pass, which is why the app uses a dark label")
    func whiteOnOrangeFails() {
        #expect(ColorContrast.ratio(0xFFFFFF, DesignTokens.accent) < 4.5)
        #expect(ColorContrast.ratio(0xFF5A00, 0xFFFFFF) < 4.5)
    }
}
