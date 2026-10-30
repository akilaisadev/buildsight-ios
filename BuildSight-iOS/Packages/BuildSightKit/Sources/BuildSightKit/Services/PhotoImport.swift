import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A library photo prepared for the capture flow.
public struct ImportedPhoto: Equatable, Sendable {
    public let jpeg: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// When the picture was taken, from its own metadata; nil if it has none.
    public let takenAt: Date?
}

/// Turns whatever the photo picker hands over (HEIC, PNG, JPEG, ...) into an upright JPEG that is
/// no larger than `maxPixelSide`, so the detector and the evidence store see the same pixels.
public enum PhotoImport {
    public static let maxPixelSide = 4096

    /// Nil when the data is not a readable image.
    public static func prepare(_ data: Data, maxPixelSide: Int = PhotoImport.maxPixelSide, quality: Double = 0.9) -> ImportedPhoto? {
        guard maxPixelSide > 0, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,        // bake in the orientation tag
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSide,
              ] as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.05), 1)] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ImportedPhoto(jpeg: output as Data, pixelWidth: image.width, pixelHeight: image.height, takenAt: takenDate(source))
    }

    /// EXIF "date taken" (no time zone is stored, so it is read as local time), or nil.
    static func takenDate(_ source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}
