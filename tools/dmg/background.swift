// The DMG window's background, at 1x and 2x: an arrow from the app to
// Applications and, while releases are not notarized, the one line that
// gets a first open past Gatekeeper.
//
// usage: xcrun swift tools/dmg/background.swift OUT_DIR HINT
//   writes OUT_DIR/background.png (600 x 420) and OUT_DIR/background@2x.png
//   HINT: 1 draws "First open: System Settings ▸ Privacy & Security ▸ Open Anyway", 0 leaves it out
// Positions are points from the top-left corner, as in tools/dmg/settings.py
// (icons at x 150 and 450, y 180).
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: background.swift OUT_DIR HINT(0|1)\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let hint = args[2] == "1"
// 420 tall: the hint stays clear of the bottom whether Finder counts its
// title bar in the window's height or not (tools/dmg/settings.py).
let width: CGFloat = 600, height: CGFloat = 420

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func draw() {
    // Light, as Finder draws icon labels over it in light mode.
    NSGradient(starting: color(0xfbfbfd), ending: color(0xececf0))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // The arrow, between the two icons (112 pt, centred at y 180 from the top).
    let y = height - 180
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 232, y: y))
    arrow.line(to: NSPoint(x: 352, y: y))
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    color(0xa1a1a6).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 370, y: y))
    head.line(to: NSPoint(x: 344, y: y + 17))
    head.line(to: NSPoint(x: 344, y: y - 17))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 3
    color(0xa1a1a6).setFill()
    color(0xa1a1a6).setStroke()
    head.fill()
    head.stroke()

    guard hint else { return }
    let text = "First open: System Settings ▸ Privacy & Security ▸ Open Anyway" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color(0x6e6e73)]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: ((width - size.width) / 2).rounded(), y: 60), withAttributes: attributes)
}

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    // Points, not pixels: the 2x image is 144 dpi, as tiffutil -cathidpicheck requires.
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { draw() }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name) (\(rep.pixelsWide) x \(rep.pixelsHigh))")
}
