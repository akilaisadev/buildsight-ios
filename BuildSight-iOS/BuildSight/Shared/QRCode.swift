import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// A QR code for a string, drawn with CoreImage. White background and a quiet zone
/// so every camera can read it, even in dark Night mode.
struct QRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.make(text) {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("QR code")
    }

    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
