// Builds the app icon and the in-app logo image from the brand logo (transparent PNG).
// Usage: swift scripts/make_app_icon.swift <logo.png> <Assets.xcassets>
// Writes AppIcon.appiconset/AppIcon.png (1024 px, opaque, no alpha) and BrandLogo.imageset/BrandLogo.png.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: make_app_icon.swift <logo.png> <Assets.xcassets>"); exit(1)
}
let assets = URL(fileURLWithPath: args[2])

func save(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func render(size: Int, opaque: Bool, scale: CGFloat) -> CGImage {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    if opaque { ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
    ctx.interpolationQuality = .high
    let side = CGFloat(size) * scale
    let o = (CGFloat(size) - side) / 2
    ctx.draw(logo, in: CGRect(x: o, y: o, width: side, height: side))
    return ctx.makeImage()!
}

// The logo artwork fills about 70% of its canvas; scale it up so it fills ~84% of the icon's height.
save(render(size: 1024, opaque: true, scale: 1.18), to: assets.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))
save(render(size: 1024, opaque: false, scale: 1.0), to: assets.appendingPathComponent("BrandLogo.imageset/BrandLogo.png"))
print("wrote AppIcon and BrandLogo")
