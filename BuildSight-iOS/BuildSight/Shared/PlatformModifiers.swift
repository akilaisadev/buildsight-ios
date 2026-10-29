import SwiftUI

/// iOS-only modifiers behind one place, so views stay readable and the rest of
/// the UI code type-checks on macOS too (used for verification during development).
extension View {
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func emailField() -> some View {
        #if os(iOS)
        textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}
