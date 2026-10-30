import Foundation

/// Rules the forms use to decide whether a required field is filled in. Kept here, away from
/// the views, so they can be tested; the views only choose the wording of the message.
public enum FormRules {
    public enum EmailCheck: Equatable, Sendable { case valid, empty, invalid }

    /// True when the text is empty or only spaces and line breaks.
    public static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `message` when the text is blank, otherwise nil.
    public static func required(_ text: String, message: String) -> String? {
        isBlank(text) ? message : nil
    }

    /// `message` when nothing is chosen, otherwise nil.
    public static func requiredChoice<Value>(_ value: Value?, message: String) -> String? {
        value == nil ? message : nil
    }

    /// Checks the shape of an email address: one "@", something before it, and a domain with at
    /// least one dot, no empty parts and a last part of two or more letters. It does not check
    /// that the mailbox exists.
    public static func email(_ text: String) -> EmailCheck {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .invalid }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return .invalid }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return .invalid }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return .invalid }
        return .valid
    }
}
