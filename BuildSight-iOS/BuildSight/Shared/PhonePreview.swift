import SwiftUI

/// Development aid: shows the iPhone layout in the Mac Catalyst window.
///
/// A Mac window always reports a "regular" width, so the app shows its iPad layout
/// and the iPhone layout (`PhoneShell`, a tab bar) can never appear. Launching with
///
///     open BuildSight.app --args -PreviewPhone YES
///
/// reports a compact width and fixes the window at iPhone size (390 x 844 points).
/// Debug builds on Mac Catalyst only: iOS and Release builds compile none of this.
/// It approximates the phone layout; fonts, safe areas and navigation chrome still
/// follow macOS rules, so it does not replace testing on an iPhone or the simulator.
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
