import SwiftUI
import AVFoundation

/// Camera-based QR scanning. It only reports raw strings; deciding whether a
/// code belongs to the active project is `AreaQRPayload.resolve`, in the
/// package, where it is unit tested.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var lastValue: String?
        private var lastTime = Date.distantPast
        private let queue = DispatchQueue(label: "buildsight.qr")

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
        }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); let s = session; queue.async { s.startRunning() } }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); let s = session; queue.async { s.stopRunning() } }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            // The camera reports the same code many times a second; debounce.
            if value == lastValue, Date().timeIntervalSince(lastTime) < 2 { return }
            lastValue = value; lastTime = Date()
            onCode?(value)
        }
    }
}
