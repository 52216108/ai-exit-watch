import AppKit

// 沿用菜单栏的盾牌标识，生成各分辨率原生应用图标。
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 196, yRadius: 196)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: NSColor.black.withAlphaComponent(0.20).cgColor)
    NSColor(calibratedRed: 0.04, green: 0.14, blue: 0.25, alpha: 1).setFill()
    tile.fill()
    cg.restoreGState()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.17, blue: 0.31, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.37, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.61, blue: 0.65, alpha: 1)
    ])!.draw(in: tile, angle: 50)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    tile.lineWidth = 3; tile.stroke()

    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 788))
    shield.curve(to: NSPoint(x: 742, y: 697), controlPoint1: NSPoint(x: 607, y: 748), controlPoint2: NSPoint(x: 682, y: 731))
    shield.line(to: NSPoint(x: 742, y: 528))
    shield.curve(to: NSPoint(x: 512, y: 245), controlPoint1: NSPoint(x: 742, y: 393), controlPoint2: NSPoint(x: 636, y: 284))
    shield.curve(to: NSPoint(x: 282, y: 528), controlPoint1: NSPoint(x: 388, y: 284), controlPoint2: NSPoint(x: 282, y: 393))
    shield.line(to: NSPoint(x: 282, y: 697))
    shield.curve(to: NSPoint(x: 512, y: 788), controlPoint1: NSPoint(x: 342, y: 731), controlPoint2: NSPoint(x: 417, y: 748))
    shield.close()
    NSColor.white.withAlphaComponent(0.06).setFill(); shield.fill()
    NSColor.white.withAlphaComponent(0.96).setStroke()
    shield.lineWidth = 34; shield.lineJoinStyle = .round; shield.stroke()

    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 357, y: 514))
    for point in [NSPoint(x: 424, y: 514), NSPoint(x: 471, y: 600), NSPoint(x: 534, y: 428), NSPoint(x: 580, y: 514), NSPoint(x: 661, y: 514)] { pulse.line(to: point) }
    NSColor(calibratedRed: 0.47, green: 1.0, blue: 0.82, alpha: 1).setStroke()
    pulse.lineWidth = 33; pulse.lineJoinStyle = .round; pulse.lineCapStyle = .round; pulse.stroke()

    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
