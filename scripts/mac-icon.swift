// Renders the macOS app icon set from the iOS 1024 px icon: the artwork inside the standard macOS rounded-rectangle
// tile (824 px on a 1024 px canvas, ~22.4% corner radius) with a soft drop shadow, at every macOS size.
import AppKit
let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
let outDir = args[2]
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    path.addClip()
    source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for px in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-mac-\(px).png"))
}
