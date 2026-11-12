// Draws the Spinaural app icon into an .iconset folder: swift tools/make-icon.swift <out.iconset>
import AppKit
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Spinaural.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let paper = NSColor(red: 0.937, green: 0.898, blue: 0.812, alpha: 1)
let ink = NSColor(red: 0.114, green: 0.102, blue: 0.086, alpha: 1)
let red = NSColor(red: 0.824, green: 0.275, blue: 0.165, alpha: 1)
func draw(_ s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let m = s * 0.09, body = NSRect(x: m, y: m, width: s - 2 * m, height: s - 2 * m)
    paper.setFill(); NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2).fill()
    let c = NSPoint(x: s / 2, y: s / 2)
    func circ(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
    ink.setFill(); circ(s * 0.27).fill()
    paper.withAlphaComponent(0.16).setStroke()
    for k in stride(from: 0.12, through: 0.25, by: 0.03) { let p = circ(s * k); p.lineWidth = max(0.5, s * 0.004); p.stroke() }
    red.setFill(); circ(s * 0.095).fill()
    paper.setFill(); circ(s * 0.018).fill()
    let orbit = circ(s * 0.355); orbit.lineWidth = max(1, s * 0.012)
    orbit.setLineDash([s * 0.03, s * 0.025], count: 2, phase: 0); ink.setStroke(); orbit.stroke()
    let a = CGFloat.pi * 0.25, dp = NSPoint(x: c.x + cos(a) * s * 0.355, y: c.y + sin(a) * s * 0.355), dr = s * 0.065
    let dot = NSBezierPath(ovalIn: NSRect(x: dp.x - dr, y: dp.y - dr, width: 2 * dr, height: 2 * dr))
    red.setFill(); dot.fill(); dot.lineWidth = max(1, s * 0.014); ink.setStroke(); dot.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
