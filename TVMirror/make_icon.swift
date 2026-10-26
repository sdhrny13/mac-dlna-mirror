// Draws the TVMirror icon: swift make_icon.swift <folder.iconset>, then iconutil -c icns.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                          xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.85, alpha: 1)])!.draw(in: bg, angle: -60)
    // TV screen
    let tv = NSRect(x: s * 0.22, y: s * 0.36, width: s * 0.56, height: s * 0.36)
    NSColor.white.setStroke()
    let frame = NSBezierPath(roundedRect: tv, xRadius: s * 0.035, yRadius: s * 0.035)
    frame.lineWidth = s * 0.035
    frame.stroke()
    // stand
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: s * 0.40, y: s * 0.27))
    stand.line(to: NSPoint(x: s * 0.60, y: s * 0.27))
    stand.lineWidth = s * 0.035
    stand.lineCapStyle = .round
    stand.stroke()
    // broadcast waves
    for (i, r) in [0.07, 0.13].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: s * 0.5, y: s * 0.47), radius: s * CGFloat(r), startAngle: 30, endAngle: 150)
        arc.lineWidth = s * 0.03
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(i == 0 ? 1 : 0.75).setStroke()
        arc.stroke()
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.475, y: s * 0.445, width: s * 0.05, height: s * 0.05)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
