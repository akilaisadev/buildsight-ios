// Draws the BuildSight app icon (1024x1024 PNG) with Core Graphics.
// Usage: swift scripts/make_app_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: orange gradient (no alpha; iOS rounds the corners).
let colors = [CGColor(red: 1.0, green: 0.55, blue: 0.16, alpha: 1), CGColor(red: 0.93, green: 0.30, blue: 0.08, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let dark = CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)

// Viewfinder corner brackets.
ctx.setStrokeColor(white); ctx.setLineWidth(52); ctx.setLineCap(.round); ctx.setLineJoin(.round)
let m: CGFloat = 170, arm: CGFloat = 150
for (x, y, dx, dy) in [(m, m, 1.0, 1.0), (size - m, m, -1.0, 1.0), (m, size - m, 1.0, -1.0), (size - m, size - m, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: x, y: y + dy * arm)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + dx * arm, y: y))
}
ctx.strokePath()

// Building: three stacked floors with windows (y grows upward in Core Graphics).
let bx: CGFloat = 352, bw: CGFloat = 320, fh: CGFloat = 104, gap: CGFloat = 18, base: CGFloat = 300
for i in 0..<3 {
    let r = CGRect(x: bx, y: base + CGFloat(i) * (fh + gap), width: bw, height: fh)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil)); ctx.setFillColor(white); ctx.fillPath()
    for w in 0..<3 {
        let wr = CGRect(x: bx + 40 + CGFloat(w) * 92, y: r.minY + 30, width: 56, height: 44)
        ctx.addPath(CGPath(roundedRect: wr, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.setFillColor(dark); ctx.fillPath()
    }
}
// Flag on the roof.
let roof = base + 3 * fh + 2 * gap
ctx.setStrokeColor(white); ctx.setLineWidth(18)
ctx.move(to: CGPoint(x: bx + 60, y: roof)); ctx.addLine(to: CGPoint(x: bx + 60, y: roof + 120)); ctx.strokePath()
ctx.setFillColor(white)
ctx.move(to: CGPoint(x: bx + 60, y: roof + 120)); ctx.addLine(to: CGPoint(x: bx + 150, y: roof + 95)); ctx.addLine(to: CGPoint(x: bx + 60, y: roof + 70)); ctx.closePath(); ctx.fillPath()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
