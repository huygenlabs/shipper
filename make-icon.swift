// Draws AppIcon.icns: blue rounded square with a white upload button. Run: swift make-icon.swift
import AppKit

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024  // drawn on Apple's 1024 icon grid: 824pt body, 100pt margin

    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSShadow().then { $0.shadowColor = .black.withAlphaComponent(0.3); $0.shadowBlurRadius = 20 * s; $0.shadowOffset = NSSize(width: 0, height: -10 * s) }.set()
    NSColor(srgbRed: 0.04, green: 0.45, blue: 1, alpha: 1).setFill()
    shape.fill()
    NSShadow().set()
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.6, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0, green: 0.33, blue: 0.88, alpha: 1))!.draw(in: shape, angle: -90)

    // White button with a blue arrow (palette: arrow layer first, then the circle).
    let config = NSImage.SymbolConfiguration(pointSize: 540 * s, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.05, green: 0.45, blue: 0.97, alpha: 1), .white]))
    let symbol = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let size = symbol.size
    symbol.draw(in: NSRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                           width: size.width, height: size.height))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSShadow {
    func then(_ f: (NSShadow) -> Void) -> NSShadow { f(self); return self }
}

for points in [16, 32, 128, 256, 512] {
    try! draw(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try! draw(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
print("Wrote \(iconset.path)")
