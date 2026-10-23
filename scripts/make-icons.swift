// Generates Resources/AppIcon.icns from Resources/Symbol.svg (the white Domnex symbol):
// the symbol on a violet gradient tile, drawn on Apple's macOS icon grid.
// Usage: swift scripts/make-icons.swift   (from the project root)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
guard let symbol = NSImage(contentsOf: resources.appendingPathComponent("Symbol.svg")) else {
    fatalError("Resources/Symbol.svg not found or unreadable")
}

// Brand violet #6c6cf4, slightly lighter at the top and deeper at the bottom.
let top = NSColor(srgbRed: 0x7A / 255, green: 0x7A / 255, blue: 0xF7 / 255, alpha: 1)
let bottom = NSColor(srgbRed: 0x5D / 255, green: 0x4A / 255, blue: 0xEE / 255, alpha: 1)

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024

    // macOS icon grid: an 824 pt tile inset 100 pt on a 1024 pt canvas.
    let tile = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 22 * scale
    shadow.set()
    bottom.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)

    let height = tile.height * 0.5
    let width = height * symbol.size.width / symbol.size.height
    symbol.draw(in: NSRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2, width: width, height: height))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = render(pixels: points * factor).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

if let preview = CommandLine.arguments.dropFirst().first {
    try render(pixels: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: preview))
}
print("Resources/AppIcon.icns")
