import AppKit

// Erzeugt AppIcon.iconset-PNGs: swift Scripts/make_icon.swift <ausgabeordner.iconset>
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.18, blue: 0.42, alpha: 1), NSColor(red: 1.0, green: 0.55, blue: 0.1, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2), angle: -55)
    // 16:9 im Hintergrund, 9:16 im Vordergrund
    let wide = NSRect(x: s * 0.17, y: s * 0.36, width: s * 0.66, height: s * 0.37)
    NSColor.white.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: wide, xRadius: s * 0.05, yRadius: s * 0.05).fill()
    let tall = NSRect(x: s * 0.355, y: s * 0.19, width: s * 0.29, height: s * 0.62)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = s * 0.04; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: tall, xRadius: s * 0.06, yRadius: s * 0.06).fill()
    NSShadow().set()
    // Untertitel-Balken und Wiedergabe-Dreieck
    NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1).setFill()
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: s * 0.465, y: s * 0.60)); tri.line(to: NSPoint(x: s * 0.465, y: s * 0.48)); tri.line(to: NSPoint(x: s * 0.56, y: s * 0.54)); tri.close(); tri.fill()
    NSColor(white: 0.1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.395, y: s * 0.30, width: s * 0.21, height: s * 0.045), xRadius: s * 0.02, yRadius: s * 0.02).fill()
    NSColor(red: 1.0, green: 0.78, blue: 0.1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.43, y: s * 0.24, width: s * 0.14, height: s * 0.04), xRadius: s * 0.02, yRadius: s * 0.02).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    try! render(base * scale).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
}
