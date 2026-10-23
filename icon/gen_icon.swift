import AppKit
import Foundation

// Generate a 1024x1024 macOS-style icon for Thoth.
// Monochrome: black rounded square, white Thoth symbol T2 (mark 1.1,
// landing/brand/thoth-marca-v2). Same path as Sources/Thoth/Views/ThothMark.swift.

let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let gc = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("Failed to create bitmap\n", stderr); exit(1)
}
let ctx = gc.cgContext
let side = CGFloat(size)

// macOS Big Sur squircle has corner radius ~22.37% of side, with 10% padding on the canvas.
let pad = side * 0.10
let rect = CGRect(x: pad, y: pad, width: side - 2*pad, height: side - 2*pad)
let radius = rect.width * 0.2237

ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
ctx.fillPath()

// Symbol T2 on its 64 × 64 grid (y down), 5-unit stroke, round caps and joins.
// Its ink (caps included) spans x 19–45, y 8.5–55.5, centred on (32, 32).
let segments: [(CGPoint, CGPoint)] = [
    (CGPoint(x: 42.5, y: 11), CGPoint(x: 42.5, y: 38.1)),
    (CGPoint(x: 42.5, y: 46.5), CGPoint(x: 42.5, y: 53)),
    (CGPoint(x: 27, y: 18), CGPoint(x: 42.5, y: 32)),
    (CGPoint(x: 21.5, y: 32), CGPoint(x: 42.5, y: 32)),
    (CGPoint(x: 27, y: 46), CGPoint(x: 42.5, y: 32)),
]
let inkHeight = rect.height * 0.58
let scale = inkHeight / 47

ctx.saveGState()
// Centre the ink on the square and flip to the grid's y-down axis.
ctx.translateBy(x: rect.midX, y: rect.midY)
ctx.scaleBy(x: scale, y: -scale)
ctx.translateBy(x: -32, y: -32)
for (start, end) in segments {
    ctx.move(to: start)
    ctx.addLine(to: end)
}
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// Save PNG
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to create PNG\n", stderr); exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "thoth_1024.png"
try png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
