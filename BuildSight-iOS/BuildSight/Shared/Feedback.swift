import SwiftUI
import UIKit

/// App-wide confirmation and error banner, shown at the top of the screen for a few seconds.
/// Use it after an action finishes ("Task created") or when a form can't be submitted.
/// Also announces the text to VoiceOver and gives a haptic tap.
@MainActor
final class Toaster: ObservableObject {
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    @Published private(set) var current: Toast?
    private var dismissal: Task<Void, Never>?

    func success(_ text: String) { show(text, isError: false) }
    func error(_ text: String) { show(text, isError: true) }

    private func show(_ text: String, isError: Bool) {
        let toast = Toast(text: text, isError: isError)
        current = toast
        UINotificationFeedbackGenerator().notificationOccurred(isError ? .error : .success)
        UIAccessibility.post(notification: .announcement, argument: text)
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self?.current == toast else { return }
            self?.current = nil
        }
    }
}

private struct ToastHost: ViewModifier {
    @ObservedObject var toaster: Toaster

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = toaster.current {
                    Label(toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .frame(minHeight: Glove.target)
                        .background(toast.isError ? Color(hex: 0xC62828) : Color(hex: 0x1E7B3A), in: Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                        .padding(.top, 8).padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.35), value: toaster.current)
    }
}

extension View {
    /// Shows the app-wide banner over this view. Attach once at the root, and again inside sheets
    /// (a sheet covers the root's banner).
    func toastHost(_ toaster: Toaster) -> some View { modifier(ToastHost(toaster: toaster)) }
}

/// Red message under a form field that is required but empty. Show it only when there is something
/// to say (`if showErrors, let e = ... { FieldError(message: e) }`) so no blank row appears.
struct FieldError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.status("high").fg)
            .accessibilityLabel("Error: \(message)")
    }
}

extension String {
    /// True when the text is empty or only spaces and line breaks.
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
