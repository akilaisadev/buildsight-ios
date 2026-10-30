import Foundation
import CoreGraphics
import CoreML
import Vision
import ImageIO

/// Raw model output for one image, before BuildSight's interpretation policy.
public struct HelmetRawResult: Sendable {
    public var observations: [HelmetObservation]
    public var quality: ImageQuality
    public var inferenceMilliseconds: Double
}

public enum HelmetAnalyzerError: Error, Equatable, Sendable {
    case modelUnavailable(String)
    case imageUnreadable
    case inferenceFailed(String)
}

public protocol HelmetAnalyzing: Sendable {
    var descriptor: HelmetModelDescriptor { get }
    func analyse(imageAt url: URL) async throws -> HelmetRawResult
}

/// Image sharpness without ML: variance of a Laplacian on a small greyscale copy. Blurry
/// photos score low. The threshold is provisional, so treat it as a rough gate.
public enum ImageSharpness {
    public static func laplacianVariance(pixels: [UInt8], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, pixels.count >= width * height else { return 0 }
        var sum = 0.0, sumSquares = 0.0
        var n = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let c = Double(pixels[y * width + x])
                let lap = Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
                    + Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1]) - 4 * c
                sum += lap; sumSquares += lap * lap; n += 1
            }
        }
        let mean = sum / n
        return sumSquares / n - mean * mean
    }

    public static func measure(_ image: CGImage, side: Int = 256) -> Double {
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = max(3, Int(Double(image.width) * min(1, scale)))
        let h = max(3, Int(Double(image.height) * min(1, scale)))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? laplacianVariance(pixels: pixels, width: w, height: h) : 0
    }
}

/// Runs the Core ML detector through Vision, fully on device (no network).
/// The photo is decoded upright and capped at 1600 px; Vision scales it to the model input
/// (`.scaleFill`, what Ultralytics exports expect). The model has NMS built in, so Vision
/// returns ready-made observations with boxes normalised to the upright image.
public final class CoreMLHelmetAnalyzer: HelmetAnalyzing, @unchecked Sendable {
    public let descriptor: HelmetModelDescriptor
    private let visionModel: VNCoreMLModel
    private let maxPixelSide = 1600

    /// - Parameter modelURL: compiled model (`.mlmodelc`) inside the app bundle,
    ///   or a `.mlpackage`/`.mlmodel` that is compiled on first use (tests, eval).
    public init(modelURL: URL, descriptor: HelmetModelDescriptor) throws {
        self.descriptor = descriptor
        do {
            var url = modelURL
            if url.pathExtension != "mlmodelc" { url = try MLModel.compileModel(at: url) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            visionModel = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
        } catch {
            throw HelmetAnalyzerError.modelUnavailable(error.localizedDescription)
        }
    }

    public func analyse(imageAt url: URL) async throws -> HelmetRawResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,      // bake in EXIF orientation
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSide,
              ] as CFDictionary) else { throw HelmetAnalyzerError.imageUnreadable }

        let quality = ImageQuality(pixelWidth: image.width, pixelHeight: image.height, sharpness: ImageSharpness.measure(image))
        let descriptor = self.descriptor
        let model = visionModel

        // Vision's perform is synchronous; keep it off the caller's executor.
        return try await Task.detached(priority: .userInitiated) {
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)

            let start = ContinuousClock.now
            do { try handler.perform([request]) }
            catch { throw HelmetAnalyzerError.inferenceFailed(error.localizedDescription) }
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15

            let observations: [HelmetObservation] = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { o in
                // Only the top label per box; unknown class names are dropped
                // rather than guessed at, so a wrong model fails loudly in eval.
                guard let top = o.labels.first, let label = descriptor.labelMap[top.identifier] else { return nil }
                let b = o.boundingBox
                return HelmetObservation(label: label, score: Double(top.confidence), box: NormalizedRect(visionRect: b.minX, y: b.minY, width: b.width, height: b.height))
            }
            return HelmetRawResult(observations: observations, quality: quality, inferenceMilliseconds: ms)
        }.value
    }
}
