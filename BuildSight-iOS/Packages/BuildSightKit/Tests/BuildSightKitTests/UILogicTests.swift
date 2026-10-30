import Testing
import Foundation
@testable import BuildSightKit

private func snapshot(unreviewed: Int = 0, confirmed: Int = 0, today: Int = 0, critical: Int = 0, area: String? = nil) -> WidgetSnapshot {
    WidgetSnapshot(projectID: Fixture.projectA, projectName: "Site", generatedAt: Fixture.now, unreviewedFlags: unreviewed, confirmedFindings: confirmed, flagsToday: today, topAreaName: area, openCritical: critical)
}

@Suite("Widget status and ring")
struct WidgetStatusTests {
    @Test("Nothing waiting and nothing critical is all clear", arguments: [0, 5, 100])
    func allClear(_ confirmed: Int) {
        #expect(snapshot(confirmed: confirmed).status == .allClear)
    }

    @Test("Flags waiting for a person show as needs review, with the count", arguments: [1, 2, 9, 10, 11, 250])
    func needsReview(_ n: Int) {
        #expect(snapshot(unreviewed: n).status == .needsReview(n))
    }

    @Test("A critical issue wins over everything else", arguments: [1, 2, 7])
    func critical(_ n: Int) {
        #expect(snapshot(unreviewed: 4, critical: n).status == .critical(n))
        #expect(snapshot(critical: n).status == .critical(n))
    }

    @Test("The ring fills one tenth per flag and stops at full", arguments: [(0, 0.0), (1, 0.1), (5, 0.5), (9, 0.9), (10, 1.0), (11, 1.0), (500, 1.0)])
    func backlogShare(_ c: (flags: Int, share: Double)) {
        #expect(abs(snapshot(unreviewed: c.flags).backlogShare - c.share) < 0.0001)
    }

    @Test("A negative count can never draw a negative ring")
    func negativeIsClamped() {
        #expect(snapshot(unreviewed: -3).backlogShare == 0)
    }

    @Test("Confirmed findings and today's count do not change the status")
    func otherCountsIgnored() {
        #expect(snapshot(confirmed: 40, today: 12).status == .allClear)
    }

    @Test("The snapshot round-trips through JSON, as the app group store does")
    func codable() throws {
        let original = snapshot(unreviewed: 3, confirmed: 8, today: 2, critical: 1, area: "Level 2")
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(original))
        #expect(back == original)
        #expect(back.status == .critical(1))
    }
}

@Suite("Face ID and Touch ID names")
struct BiometricKindTests {
    @Test("Each sensor has a name and an icon", arguments: [(BiometricKind.faceID, "Face ID", "faceid"), (.touchID, "Touch ID", "touchid"), (.opticID, "Optic ID", "opticid")])
    func names(_ c: (kind: BiometricKind, name: String, symbol: String)) {
        #expect(c.kind.displayName == c.name)
        #expect(c.kind.symbolName == c.symbol)
    }

    @Test("A device with no biometrics has neither name nor icon")
    func none() {
        #expect(BiometricKind.none.displayName == nil)
        #expect(BiometricKind.none.symbolName == nil)
    }

    @Test("The names are distinct, so screens never mix them up")
    func distinct() {
        let names = [BiometricKind.faceID, .touchID, .opticID].compactMap(\.displayName)
        #expect(Set(names).count == 3)
    }
}

@Suite("Form rules, more cases")
struct FormRulesMoreTests {
    @Test("Common real-world addresses are accepted", arguments: [
        "akila@nvylo.com", "first.last@company.co.lk", "a-b_c@x-y.org", "user+tag@gmail.com", "u@sub.domain.example.com", "12345@numbers.net", "MiXeD@CaSe.CoM",
    ])
    func accepted(_ text: String) { #expect(FormRules.email(text) == .valid) }

    @Test("Typical typing mistakes are rejected", arguments: [
        "test@gmail", "test@gmail,com", "test@@gmail.com", "test gmail.com", "test@gmail..com", ".@.", "@", "a@", "@a.com", "test@gmail.c", "test@-.com ", "t@t.t1",
    ])
    func rejected(_ text: String) { #expect(FormRules.email(text) != .valid) }

    @Test("Padding around a good address is ignored", arguments: [" a@b.co", "a@b.co ", "\ta@b.co\n", "  a@b.co  "])
    func padding(_ text: String) { #expect(FormRules.email(text) == .valid) }

    @Test("Required text keeps its own message", arguments: ["Enter a title.", "Say why.", "Pick an area."])
    func message(_ message: String) {
        #expect(FormRules.required("", message: message) == message)
        #expect(FormRules.required("ok", message: message) == nil)
    }

    @Test("Only whitespace characters make text blank", arguments: [("\u{00A0}", true), ("\u{2003}", true), ("\u{200B}", true), ("-", false), (".", false)])
    func whitespaceKinds(_ c: (text: String, blank: Bool)) {
        #expect(FormRules.isBlank(c.text) == c.blank)
    }

    @Test("A long title is still fine", arguments: [10, 200, 5000])
    func longText(_ n: Int) {
        #expect(!FormRules.isBlank(String(repeating: "x", count: n)))
    }
}
