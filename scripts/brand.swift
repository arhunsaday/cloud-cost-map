// Generates every brand asset from the geometry below, so the app icon, the
// SVG logo and the README image can never drift apart.
// Run with `make brand` (or `swift scripts/brand.swift`). Output is committed.
import AppKit
import CoreGraphics
import Foundation

struct Brand {
    static let name = "Cloud Cost Map"
    static let backgroundTop = "#312E81"    // indigo
    static let backgroundBottom = "#0F172A" // slate night
    static let cloud = "#FFFFFF"
}

/// A ring segment, angles as fractions of a turn from 12 o'clock, clockwise.
struct Segment {
    let start: Double, end: Double, inner: Double, outer: Double, color: String
}

/// The mark: a two-ring sunburst around a cloud. Inner ring = services, outer
/// ring = the resources inside them, with one amber "hotspot".
let segments: [Segment] = {
    let r1 = (118.0, 208.0), r2 = (218.0, 300.0)
    return [
        Segment(start: 0.00, end: 0.46, inner: r1.0, outer: r1.1, color: "#3B82F6"),
        Segment(start: 0.46, end: 0.74, inner: r1.0, outer: r1.1, color: "#8B5CF6"),
        Segment(start: 0.74, end: 1.00, inner: r1.0, outer: r1.1, color: "#14B8A6"),
        Segment(start: 0.00, end: 0.24, inner: r2.0, outer: r2.1, color: "#60A5FA"),
        Segment(start: 0.24, end: 0.37, inner: r2.0, outer: r2.1, color: "#93C5FD"),
        Segment(start: 0.37, end: 0.46, inner: r2.0, outer: r2.1, color: "#F59E0B"),
        Segment(start: 0.46, end: 0.65, inner: r2.0, outer: r2.1, color: "#A78BFA"),
        Segment(start: 0.74, end: 0.87, inner: r2.0, outer: r2.1, color: "#2DD4BF"),
        Segment(start: 0.87, end: 0.95, inner: r2.0, outer: r2.1, color: "#5EEAD4"),
    ]
}()

/// Cloud = three circles over a rounded base, centred on the origin.
let cloudScale: Double = 1.4
let cloudUnit: [(x: Double, y: Double, r: Double)] = [(-30, 6, 30), (8, -14, 40), (42, 10, 25)]
let cloudCircles: [(x: Double, y: Double, r: Double)] = cloudUnit.map { c in
    (x: c.x * cloudScale, y: c.y * cloudScale + 4, r: c.r * cloudScale)
}
let cloudBase: (x: Double, y: Double, w: Double, h: Double, r: Double) =
    (x: -62 * cloudScale, y: 4 * cloudScale + 4, w: 128 * cloudScale, h: 34 * cloudScale, r: 17 * cloudScale)

let canvas = 1024.0
let center = 512.0
// macOS icon grid: 824 pt body inset 100 pt, continuous corners.
let body = (inset: 100.0, size: 824.0, radius: 185.0)

func rgba(_ hex: String) -> CGColor {
    let v = UInt64(hex.dropFirst(), radix: 16)!
    return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

/// Angular padding so neighbouring segments are separated by a constant gap.
func padded(_ s: Segment, gap: Double) -> (Double, Double, Double, Double) {
    let a0 = s.start * 2 * .pi + gap / s.outer
    let a1 = s.end * 2 * .pi - gap / s.outer
    let b0 = s.start * 2 * .pi + gap / s.inner
    let b1 = s.end * 2 * .pi - gap / s.inner
    return (a0, a1, b0, b1)
}

func point(_ angle: Double, _ r: Double) -> CGPoint {
    CGPoint(x: center + r * sin(angle), y: center - r * cos(angle))
}

// MARK: - Raster

func draw(size: Int) -> Data {
    let scale = Double(size) / canvas
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a 1024, y-down space.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

    let rect = CGRect(x: body.inset, y: body.inset, width: body.size, height: body.size)
    let tile = CGPath(roundedRect: rect, cornerWidth: body.radius, cornerHeight: body.radius, transform: nil)

    ctx.saveGState()
    // Shadows ignore the CTM, so "down" is negative in device space.
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(rgba(Brand.backgroundBottom))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgba(Brand.backgroundTop), rgba(Brand.backgroundBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Soft glow behind the mark.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(srgbRed: 0.55, green: 0.6, blue: 1, alpha: 0.28), CGColor(srgbRed: 0.55, green: 0.6, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: center, y: center), startRadius: 0,
                           endCenter: CGPoint(x: center, y: center), endRadius: 380, options: [])
    ctx.restoreGState()

    for s in segments {
        let (a0, a1, b0, b1) = padded(s, gap: 7)
        let path = CGMutablePath()
        // CoreGraphics angles: 0 = +x, measured toward +y (down here), so 12 o'clock = -π/2.
        path.addArc(center: CGPoint(x: center, y: center), radius: s.outer, startAngle: a0 - .pi / 2, endAngle: a1 - .pi / 2, clockwise: false)
        path.addArc(center: CGPoint(x: center, y: center), radius: s.inner, startAngle: b1 - .pi / 2, endAngle: b0 - .pi / 2, clockwise: true)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(rgba(s.color))
        ctx.fillPath()
    }

    ctx.setFillColor(rgba(Brand.cloud))
    for c in cloudCircles {
        ctx.fillEllipse(in: CGRect(x: center + c.x - c.r, y: center + c.y - c.r, width: c.r * 2, height: c.r * 2))
    }
    ctx.addPath(CGPath(roundedRect: CGRect(x: center + cloudBase.x, y: center + cloudBase.y, width: cloudBase.w, height: cloudBase.h),
                       cornerWidth: cloudBase.r, cornerHeight: cloudBase.r, transform: nil))
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - SVG

func svg() -> String {
    func f(_ v: Double) -> String { String(format: "%.2f", v) }
    var out = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="\(Brand.name)">
      <defs>
        <linearGradient id="bg" x1="300" y1="100" x2="724" y2="924" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(Brand.backgroundTop)"/><stop offset="1" stop-color="\(Brand.backgroundBottom)"/>
        </linearGradient>
        <radialGradient id="glow" cx="512" cy="512" r="380" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#8C99FF" stop-opacity="0.28"/><stop offset="1" stop-color="#8C99FF" stop-opacity="0"/>
        </radialGradient>
      </defs>
      <rect x="\(f(body.inset))" y="\(f(body.inset))" width="\(f(body.size))" height="\(f(body.size))" rx="\(f(body.radius))" fill="url(#bg)"/>
      <rect x="\(f(body.inset))" y="\(f(body.inset))" width="\(f(body.size))" height="\(f(body.size))" rx="\(f(body.radius))" fill="url(#glow)"/>

    """
    for s in segments {
        let (a0, a1, b0, b1) = padded(s, gap: 7)
        let large = (a1 - a0) > .pi ? 1 : 0
        let p0 = point(a0, s.outer), p1 = point(a1, s.outer), q1 = point(b1, s.inner), q0 = point(b0, s.inner)
        out += "  <path fill=\"\(s.color)\" d=\"M\(f(p0.x)) \(f(p0.y)) A\(f(s.outer)) \(f(s.outer)) 0 \(large) 1 \(f(p1.x)) \(f(p1.y)) L\(f(q1.x)) \(f(q1.y)) A\(f(s.inner)) \(f(s.inner)) 0 \(large) 0 \(f(q0.x)) \(f(q0.y))Z\"/>\n"
    }
    out += "  <g fill=\"\(Brand.cloud)\">\n"
    for c in cloudCircles { out += "    <circle cx=\"\(f(center + c.x))\" cy=\"\(f(center + c.y))\" r=\"\(f(c.r))\"/>\n" }
    out += "    <rect x=\"\(f(center + cloudBase.x))\" y=\"\(f(center + cloudBase.y))\" width=\"\(f(cloudBase.w))\" height=\"\(f(cloudBase.h))\" rx=\"\(f(cloudBase.r))\"/>\n"
    out += "  </g>\n</svg>\n"
    return out
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: root.appending(path: "brand"), withIntermediateDirectories: true)
try draw(size: 1024).write(to: root.appending(path: "brand/icon-1024.png"))
try draw(size: 256).write(to: root.appending(path: "brand/icon-256.png"))
try svg().write(to: root.appending(path: "brand/logo.svg"), atomically: true, encoding: .utf8)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Brand assets: Resources/AppIcon.icns, brand/icon-1024.png, brand/icon-256.png, brand/logo.svg")
