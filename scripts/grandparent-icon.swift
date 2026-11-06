import AppKit

// Renders the Grandparent Chat app icon (1024x1024, opaque; iOS applies the corner mask).
// Usage: swift scripts/grandparent-icon.swift <output.png>
let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colours = [CGColor(red: 0.98, green: 0.62, blue: 0.25, alpha: 1), CGColor(red: 0.89, green: 0.36, blue: 0.20, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let configuration = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
    let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
        symbol.draw(in: bounds)
        NSColor.white.set()
        bounds.fill(using: .sourceAtop)
        return true
    }
    let target = NSRect(x: (CGFloat(size) - tinted.size.width) / 2, y: (CGFloat(size) - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: target)
}
NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
