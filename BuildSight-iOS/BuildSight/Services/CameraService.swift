import SwiftUI
@preconcurrency import AVFoundation

enum CameraAvailability: Equatable {
    case ready, notDetermined, denied, restricted, noCamera
}

/// Owns the AVCaptureSession for still photos. Configuration and start/stop run
/// on a private serial queue (AVFoundation's requirement), and the session is
/// stopped when the view disappears so the camera light never stays on.
@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var availability: CameraAvailability = .notDetermined
    @Published private(set) var isCapturing = false
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "buildsight.camera")
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var continuation: CheckedContinuation<Data?, Never>?

    func prepare() async {
        guard AVCaptureDevice.default(for: .video) != nil else { availability = .noCamera; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: availability = .ready
        case .notDetermined:
            availability = await AVCaptureDevice.requestAccess(for: .video) ? .ready : .denied
        case .denied: availability = .denied
        case .restricted: availability = .restricted
        @unknown default: availability = .denied
        }
        guard availability == .ready else { return }
        await configureIfNeeded()
        start()
    }

    private func configureIfNeeded() async {
        guard !configured else { return }
        configured = true
        let session = self.session, output = self.output
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                session.beginConfiguration()
                session.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                done.resume()
            }
        }
    }

    func start() { let s = session; queue.async { if !s.isRunning { s.startRunning() } } }
    func stop() { let s = session; queue.async { if s.isRunning { s.stopRunning() } } }

    /// Returns JPEG data, or nil if capture failed.
    func capture() async -> Data? {
        guard availability == .ready, !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        return await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            continuation = c
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            output.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in
            self.continuation?.resume(returning: data)
            self.continuation = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
