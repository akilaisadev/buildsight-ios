// Development-only: lets the SwiftUI layer be type-checked with the macOS SDK
// when full Xcode (and the iOS SDK) is not available. NOT part of the app target.
import SwiftUI
import AppKit

extension View {
    func fullScreenCover<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View { sheet(isPresented: isPresented, content: content) }
}
extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .automatic }
    static var topBarLeading: ToolbarItemPlacement { .automatic }
}
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
extension NSImage { convenience init?(data: Data) { self.init(data: data as Data) } }
protocol UIViewRepresentable: NSViewRepresentable {}
protocol UIViewControllerRepresentable: NSViewControllerRepresentable {}

// Stand-ins for the AVFoundation views, which need the iOS SDK.
enum CameraAvailability: Equatable { case ready, notDetermined, denied, restricted, noCamera }
@MainActor final class CameraService: ObservableObject {
    @Published var availability: CameraAvailability = .ready
    @Published var isCapturing = false
    let session = 0
    func prepare() async {}
    func stop() {}
    func capture() async -> Data? { nil }
}
struct CameraPreview: View { let session: Int; var body: some View { EmptyView() } }
struct QRScannerView: View { let onCode: (String) -> Void; var body: some View { EmptyView() } }
