// Draws the app icon and writes it as an .icns file: swift scripts/make-icon.swift <out.icns>
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The icon on a 1024-point canvas: a page-coloured tile in the system's icon shape with a heavy
/// "M" and a text caret in the accent colour beside it.
func draw(in context: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.3))
    context.addPath(shape)
    context.setFillColor(color(0x2A2C30))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let page = CGGradient(colorsSpace: space, colors: [color(0x34373D), color(0x1D1E21)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(page, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    let font = NSFont.systemFont(ofSize: 560, weight: .heavy)
    let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 560) } ?? font
    let letter = NSAttributedString(string: "M", attributes: [.font: rounded, .foregroundColor: NSColor(cgColor: color(0xFCFCFB))!])
    let line = CTLineCreateWithAttributedString(letter)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let caretWidth: CGFloat = 44, gap: CGFloat = 46
    let left = tile.midX - (bounds.width + gap + caretWidth) / 2
    context.textPosition = CGPoint(x: left - bounds.minX, y: tile.midY - bounds.midY)
    CTLineDraw(line, context)

    let caret = CGRect(x: left + bounds.width + gap, y: tile.midY - bounds.height / 2 - 40, width: caretWidth, height: bounds.height + 80)
    context.addPath(CGPath(roundedRect: caret, cornerWidth: caretWidth / 2, cornerHeight: caretWidth / 2, transform: nil))
    context.setFillColor(color(0x4C8DF6))
    context.fillPath()
}

guard CommandLine.arguments.count == 2 else {
    print("usage: make-icon.swift <out.icns>")
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(in: context)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
