import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum EvidenceFileError: Error, Equatable, Sendable {
    case unreadableImage
    case writeFailed
}

/// Keeps original evidence on disk, outside Core Data, one JPEG per photo id.
///
/// The image is re-encoded upright once on save so EXIF orientation can never
/// disagree between the display, the detector and the uploaded file. No overlay
/// is ever drawn into these files: boxes are rendered at display time.
public struct EvidenceFileStore: EvidenceFileStoring {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(jpeg: Data, photoID: UUID) throws -> SavedEvidence {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else { throw EvidenceFileError.unreadableImage }

        let filename = "\(photoID.uuidString).jpg"
        let url = self.url(forFilename: filename)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw EvidenceFileError.writeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EvidenceFileError.writeFailed }
        return SavedEvidence(filename: filename, pixelWidth: image.width, pixelHeight: image.height)
    }

    public func url(forFilename filename: String) -> URL {
        // lastPathComponent: a filename from a synced record must never escape the folder.
        directory.appendingPathComponent((filename as NSString).lastPathComponent)
    }

    public func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(forFilename: filename))
    }
}
