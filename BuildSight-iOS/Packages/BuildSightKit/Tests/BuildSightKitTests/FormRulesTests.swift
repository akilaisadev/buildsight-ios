import Testing
import Foundation
@testable import BuildSightKit

@Suite("Form rules")
struct FormRulesTests {
    @Test("Blank text is empty, spaces, tabs or line breaks only", arguments: ["", " ", "   ", "\n", "\t", " \n\t "])
    func blank(_ text: String) {
        #expect(FormRules.isBlank(text))
        #expect(FormRules.required(text, message: "needed") == "needed")
    }

    @Test("Text with any visible character is not blank", arguments: ["a", " a ", "0", "ශ්‍රී", "👷", "\nx"])
    func notBlank(_ text: String) {
        #expect(!FormRules.isBlank(text))
        #expect(FormRules.required(text, message: "needed") == nil)
    }

    @Test("A choice is required until something is picked")
    func choice() {
        let none: UUID? = nil
        #expect(FormRules.requiredChoice(none, message: "pick one") == "pick one")
        #expect(FormRules.requiredChoice(Optional(UUID()), message: "pick one") == nil)
        #expect(FormRules.requiredChoice(Optional(0), message: "pick one") == nil)   // zero is a choice
    }

    @Test("Well-formed email addresses are accepted", arguments: [
        "test@gmail.com", "a.b+c@sub.example.co.uk", "  padded@example.com  ", "UPPER@EXAMPLE.COM", "x@y.io", "name_1@my-site.lk",
    ])
    func validEmails(_ text: String) {
        #expect(FormRules.email(text) == .valid)
    }

    @Test("Empty input is reported as empty, not invalid", arguments: ["", " ", "\n"])
    func emptyEmails(_ text: String) {
        #expect(FormRules.email(text) == .empty)
    }

    @Test("Malformed email addresses are rejected", arguments: [
        "plain", "no-at.example.com", "@example.com", "user@", "user@example", "user@example.", "user@.com",
        "user@@example.com", "a@b@example.com", "user name@example.com", "user@exa mple.com", "user@example.c", "user@example.c0m", "user@exa..mple.com",
    ])
    func invalidEmails(_ text: String) {
        #expect(FormRules.email(text) == .invalid)
    }
}
