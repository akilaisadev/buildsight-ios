// Generates the full-bleed 1024 px building icon from the same geometry as BrandMark.
// Usage: swift scripts/make_app_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
guard let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create app icon canvas")
}
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(red: 43.0 / 255, green: 52.0 / 255, blue: 64.0 / 255, alpha: 1),
    CGColor(red: 16.0 / 255, green: 22.0 / 255, blue: 29.0 / 255, alpha: 1)
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: .zero, end: CGPoint(x: size, y: size), options: [])

let orange = CGColor(red: 1, green: 90.0 / 255.0, blue: 0, alpha: 1)
let edge = CGColor(red: 231.0 / 255, green: 237.0 / 255, blue: 240.0 / 255, alpha: 1)
let window = CGColor(red: 21.0 / 255, green: 35.0 / 255, blue: 45.0 / 255, alpha: 1)

func fillPolygon(_ points: [CGPoint], color: CGColor) {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
}

fillPolygon([
    CGPoint(x: 0.66 * size, y: 0.29 * size), CGPoint(x: 0.80 * size, y: 0.20 * size),
    CGPoint(x: 0.80 * size, y: 0.72 * size), CGPoint(x: 0.66 * size, y: 0.81 * size)
], color: CGColor(red: 38.0 / 255, green: 52.0 / 255, blue: 62.0 / 255, alpha: 1))

let roof = CGMutablePath()
roof.addLines(between: [
    CGPoint(x: 0.25 * size, y: 0.29 * size), CGPoint(x: 0.39 * size, y: 0.20 * size),
    CGPoint(x: 0.80 * size, y: 0.20 * size), CGPoint(x: 0.66 * size, y: 0.29 * size)
])
roof.closeSubpath()
context.saveGState()
context.addPath(roof)
context.clip()
let roofGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [orange, CGColor(red: 1, green: 155.0 / 255, blue: 69.0 / 255, alpha: 1)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(roofGradient, start: CGPoint(x: 0.25 * size, y: 0.25 * size), end: CGPoint(x: 0.80 * size, y: 0.25 * size), options: [])
context.restoreGState()

context.saveGState()
context.clip(to: CGRect(x: 0.25 * size, y: 0.29 * size, width: 0.41 * size, height: 0.52 * size))
let frontGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(red: 73.0 / 255, green: 90.0 / 255, blue: 102.0 / 255, alpha: 1),
    CGColor(red: 39.0 / 255, green: 54.0 / 255, blue: 64.0 / 255, alpha: 1)
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(frontGradient, start: CGPoint(x: 0.25 * size, y: 0.29 * size), end: CGPoint(x: 0.66 * size, y: 0.81 * size), options: [])
context.restoreGState()

context.setStrokeColor(edge)
context.setLineWidth(0.018 * size)
for floor in 0..<4 {
    let y = (0.355 + CGFloat(floor) * 0.137) * size
    context.move(to: CGPoint(x: 0.25 * size, y: y))
    context.addLine(to: CGPoint(x: 0.66 * size, y: y))
    context.addLine(to: CGPoint(x: 0.80 * size, y: y - 0.09 * size))
    context.strokePath()
}

for row in 0..<3 {
    for column in 0..<3 {
        let centerX = (0.325 + CGFloat(column) * 0.113) * size
        let centerY = (0.407 + CGFloat(row) * 0.137) * size
        let rect = CGRect(x: centerX - 0.034 * size, y: centerY - 0.0375 * size, width: 0.068 * size, height: 0.075 * size)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 0.006 * size, cornerHeight: 0.006 * size, transform: nil))
        context.setFillColor((row == 0 && column == 2) || (row == 2 && column == 0) ? orange : window)
        context.fillPath()
    }
}

context.setStrokeColor(edge)
context.setLineWidth(0.013 * size)
context.move(to: CGPoint(x: 0.25 * size, y: 0.29 * size))
context.addLine(to: CGPoint(x: 0.25 * size, y: 0.81 * size))
context.addLine(to: CGPoint(x: 0.66 * size, y: 0.81 * size))
context.addLine(to: CGPoint(x: 0.80 * size, y: 0.72 * size))
context.strokePath()

guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("Could not encode app icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
