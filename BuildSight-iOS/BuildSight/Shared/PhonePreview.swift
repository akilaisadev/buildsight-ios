import SwiftUI

/// Debug aid: shows the iPhone layout in the Mac Catalyst window (a Mac always reports a
/// regular width). Run `open BuildSight.app --args -PreviewPhone YES` for a 390 x 844 window.
/// Not a substitute for testing on a phone.
#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

enum PhonePreview {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "PreviewPhone") }
    static let size = CGSize(width: 390, height: 844)
}

private struct WindowSizer: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { SizerView() }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class SizerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let restrictions = window?.windowScene?.sizeRestrictions else { return }
            restrictions.minimumSize = PhonePreview.size
            restrictions.maximumSize = PhonePreview.size
        }
    }
}

extension View {
    @ViewBuilder func phonePreviewIfRequested() -> some View {
        if PhonePreview.isOn {
            environment(\.horizontalSizeClass, .compact)
                .environment(\.verticalSizeClass, .regular)
                .background(WindowSizer())
        } else {
            self
        }
    }
}
#else
extension View {
    func phonePreviewIfRequested() -> some View { self }
}
#endif
