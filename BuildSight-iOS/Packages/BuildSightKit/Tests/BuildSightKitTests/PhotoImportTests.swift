import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import BuildSightKit

/// Builds a real image in the requested format so the import code runs through ImageIO for real.
func makeImageData(width: Int, height: Int, type: UTType = .jpeg, orientation: Int? = nil, takenAt: String? = nil, noisy: Bool = false) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if noisy {
        var seed: UInt64 = 42
        for _ in 0..<(width * height / 8) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            ctx.setFillColor(CGColor(red: Double(seed >> 56) / 255, green: Double((seed >> 48) & 255) / 255, blue: Double((seed >> 40) & 255) / 255, alpha: 1))
            ctx.fill(CGRect(x: Int((seed >> 20) % UInt64(width)), y: Int((seed >> 8) % UInt64(height)), width: 2, height: 2))
        }
    }
    var properties: [CFString: Any] = [:]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    if let takenAt { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: takenAt] }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func dimensions(of jpeg: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

@Suite("Photo import")
struct PhotoImportTests {
    @Test("The output is always a JPEG, whatever format came in", arguments: [UTType.jpeg, .png, .tiff, .gif, .bmp])
    func outputIsJPEG(_ type: UTType) throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: 120, height: 80, type: type)))
        #expect(photo.jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        let source = try #require(CGImageSourceCreateWithData(photo.jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    }

    @Test("Images that fit are kept at their size, never enlarged", arguments: [(1, 1), (64, 48), (640, 480), (480, 640), (4096, 10), (300, 300)])
    func keepsSmallSizes(_ size: (Int, Int)) throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: size.0, height: size.1)))
        #expect(photo.pixelWidth == size.0 && photo.pixelHeight == size.1)
    }

    @Test("Large images are scaled down so the longest side fits, keeping the shape", arguments: [
        (400, 200, 100, 100, 50), (200, 400, 100, 50, 100), (300, 300, 150, 150, 150), (1000, 10, 100, 100, 1), (640, 480, 320, 320, 240),
    ])
    func scalesDown(_ c: (w: Int, h: Int, max: Int, expectW: Int, expectH: Int)) throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: c.w, height: c.h), maxPixelSide: c.max))
        #expect(photo.pixelWidth == c.expectW && photo.pixelHeight == c.expectH)
    }

    @Test("Reported size matches the pixels actually in the JPEG")
    func reportedSizeMatchesData() throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: 500, height: 300), maxPixelSide: 200))
        let real = try #require(dimensions(of: photo.jpeg))
        #expect(real.0 == photo.pixelWidth && real.1 == photo.pixelHeight)
    }

    @Test("The orientation tag is applied: sideways shots come out upright", arguments: [(5, true), (6, true), (7, true), (8, true), (1, false), (2, false), (3, false), (4, false)])
    func orientation(_ c: (tag: Int, swaps: Bool)) throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: 200, height: 100, orientation: c.tag)))
        if c.swaps { #expect(photo.pixelWidth == 100 && photo.pixelHeight == 200) }
        else { #expect(photo.pixelWidth == 200 && photo.pixelHeight == 100) }
    }

    @Test("The re-encoded JPEG carries no orientation tag, so it cannot be rotated twice")
    func noOrientationLeft() throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: 200, height: 100, orientation: 6)))
        let source = try #require(CGImageSourceCreateWithData(photo.jpeg as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tag = props[kCGImagePropertyOrientation] as? Int ?? 1
        #expect(tag == 1)
    }

    @Test("The date the picture was taken is read from its metadata")
    func readsTakenDate() throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: 80, height: 60, takenAt: "2026:10:30 14:15:16")))
        let date = try #require(photo.takenAt)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 30)
        #expect(parts.hour == 14 && parts.minute == 15 && parts.second == 16)
    }

    @Test("A picture without a date gives nil, not today's date")
    func noDate() throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: 80, height: 60)))
        #expect(photo.takenAt == nil)
    }

    @Test("An unreadable date string gives nil", arguments: ["not a date", "", "2026-10-30 14:15:16", "2026:13:45 99:99:99"])
    func badDate(_ text: String) throws {
        let photo = try #require(PhotoImport.prepare(makeImageData(width: 80, height: 60, takenAt: text)))
        #expect(photo.takenAt == nil)
    }

    @Test("Data that is not an image is rejected", arguments: [Data(), Data("hello".utf8), Data(repeating: 0, count: 64), Data([0xFF, 0xD8, 0xFF]), Data("<html></html>".utf8)])
    func rejectsGarbage(_ data: Data) {
        #expect(PhotoImport.prepare(data) == nil)
    }

    @Test("A size limit of zero or less is rejected", arguments: [0, -1, -4096])
    func rejectsBadLimit(_ limit: Int) {
        #expect(PhotoImport.prepare(makeJPEG(), maxPixelSide: limit) == nil)
    }

    @Test("Higher quality gives a bigger file than lower quality")
    func qualityChangesSize() throws {
        let data = makeImageData(width: 400, height: 300, noisy: true)
        let low = try #require(PhotoImport.prepare(data, quality: 0.1))
        let high = try #require(PhotoImport.prepare(data, quality: 1.0))
        #expect(low.jpeg.count < high.jpeg.count)
    }

    @Test("Quality outside 0 to 1 is clamped instead of failing", arguments: [-5.0, 0.0, 1.0, 2.5, 100.0])
    func qualityIsClamped(_ quality: Double) throws {
        #expect(PhotoImport.prepare(makeJPEG(width: 64, height: 64), quality: quality) != nil)
    }

    @Test("The default size limit is 4096")
    func defaultLimit() {
        #expect(PhotoImport.maxPixelSide == 4096)
    }

    @Test("Importing twice gives the same size, so the step is repeatable")
    func repeatable() throws {
        let first = try #require(PhotoImport.prepare(makeImageData(width: 300, height: 200), maxPixelSide: 100))
        let second = try #require(PhotoImport.prepare(first.jpeg, maxPixelSide: 100))
        #expect(first.pixelWidth == second.pixelWidth && first.pixelHeight == second.pixelHeight)
    }
}
