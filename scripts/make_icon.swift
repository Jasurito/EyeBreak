// Renders the 1024x1024 app icon PNG: white eye on a teal rounded square.
// Usage: make_icon <output.png>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let side = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt body centered in the 1024pt canvas.
let canvas = NSRect(x: 0, y: 0, width: side, height: side)
let body = canvas.insetBy(dx: 100, dy: 100)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.72, alpha: 1),
           ending: NSColor(calibratedRed: 0.04, green: 0.42, blue: 0.55, alpha: 1))!
    .draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let eye = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let size = eye.size
    eye.draw(in: NSRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2,
                        width: size.width, height: size.height))
}

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: output)
