// Renders the AgentMaster app icon (ADR 0008) and writes Assets/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root; needs iconutil, which ships with macOS)
//
// Design: a geometric blue A laid over a grey M on the app's dark background. A's whole triangular
// silhouette, plus a thin gap, is cut out of M, so M never shows between A's legs.
import AppKit

let size: CGFloat = 1024
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
// Theme tokens: bg #1e1e22, accent #5aa0ff, text #ccd3db.
let blue = color(0x5aa0ff), grey = color(0xccd3db)
// macOS icon grid: an 824pt rounded body inside the 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
func bodyShape() -> NSBezierPath { NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185) }
var ctx: CGContext { NSGraphicsContext.current!.cgContext }

/// Letter geometry lives in a 0…1 box (y grows downward) centred on the body.
let box = CGRect(x: 262, y: 300, width: 500, height: 424)
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * box.width, y: box.maxY - y * box.height) }
func polyline(_ points: [(CGFloat, CGFloat)], closed: Bool = false) -> CGPath {
    let path = CGMutablePath()
    path.move(to: point(points[0].0, points[0].1))
    for p in points.dropFirst() { path.addLine(to: point(p.0, p.1)) }
    if closed { path.closeSubpath() }
    return path
}
func outline(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}
func fill(_ path: CGPath, _ c: NSColor) { ctx.addPath(path); ctx.setFillColor(c.cgColor); ctx.fillPath() }
func clear(_ path: CGPath) { ctx.saveGState(); ctx.setBlendMode(.clear); ctx.addPath(path); ctx.fillPath(); ctx.restoreGState() }

let weight: CGFloat = 92, gap: CGFloat = 30
let aLegs: [(CGFloat, CGFloat)] = [(0.0, 1.0), (0.27, 0.0), (0.54, 1.0)]
let aBar: [(CGFloat, CGFloat)] = [(0.13, 0.64), (0.41, 0.64)]
// M's left stem would sit almost entirely behind A; leaving it out avoids a stray sliver beside A's right leg.
let mStrokes: [(CGFloat, CGFloat)] = [(0.46, 0.0), (0.73, 0.6), (1.0, 0.0), (1.0, 1.0)]

func drawIcon() {
    ctx.saveGState()
    bodyShape().addClip()
    NSGradient(starting: color(0x2e2e36), ending: color(0x121216))!.draw(in: bodyShape(), angle: -90)
    NSGradient(starting: color(0xffffff, 0.16), ending: color(0xffffff, 0))!.draw(in: bodyShape(), angle: -90)

    let hull = polyline(aLegs, closed: true)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: color(0x000000, 0.32).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(outline(polyline(mStrokes), width: weight * 0.8), grey)
    clear(hull)
    clear(outline(hull, width: weight + 2 * gap))
    fill(outline(polyline(aLegs), width: weight), blue)
    fill(outline(polyline(aBar), width: weight * 0.75), blue)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)   // draw each size natively, no resampling
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try! fm.createDirectory(at: URL(fileURLWithPath: "Assets"), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Assets/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try! render(pixels: 1024).write(to: URL(fileURLWithPath: "Assets/AppIcon-1024.png"))
print("Wrote Assets/AppIcon.icns")
