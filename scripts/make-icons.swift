// Renders the Castnet icon at every size the app (.iconset) and the extension need.
// The mark: a cast net (white rim shaped like a cup, its mesh inside) catching a coral
// play triangle that points down (play + download in one shape), on a teal-to-deep-blue squircle.
// usage: swift scripts/make-icons.swift <iconset-dir> <extension-icons-dir> [large-png]
import AppKit

/// Apple-style continuous corner shape (superellipse).
func squircle(_ r: CGRect, n: CGFloat = 4.2) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + a * copysign(pow(abs(c), 2 / n), c), y: r.midY + b * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Triangle pointing down with rounded corners.
func roundedTriangle(top: CGFloat, tip: CGFloat, cx: CGFloat, halfWidth: CGFloat, radius: CGFloat) -> CGPath {
    let a = CGPoint(x: cx - halfWidth, y: top), b = CGPoint(x: cx + halfWidth, y: top), c = CGPoint(x: cx, y: tip)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (a.x + b.x) / 2, y: top))
    p.addArc(tangent1End: b, tangent2End: c, radius: radius)
    p.addArc(tangent1End: c, tangent2End: a, radius: radius)
    p.addArc(tangent1End: a, tangent2End: b, radius: radius)
    p.closeSubpath()
    return p
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let small = size <= 32
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a soft shadow; nearly full-bleed at toolbar sizes.
    let inset = size >= 64 ? s * 100 / 1024 : s * 0.03
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let body = squircle(rect)
    let w = rect.width

    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: rgb(0, 0, 0, 0.32))
        ctx.addPath(body)
        ctx.setFillColor(rgb(0.08, 0.30, 0.55))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Background: lagoon teal (top left) to deep sea blue (bottom right), with a soft light.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.13, 0.78, 0.72), rgb(0.06, 0.45, 0.66), rgb(0.07, 0.17, 0.47)], [0, 0.5, 1]),
                           start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.drawRadialGradient(gradient([rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)]),
                           startCenter: CGPoint(x: rect.minX + w * 0.28, y: rect.maxY - w * 0.18), startRadius: 0,
                           endCenter: CGPoint(x: rect.minX + w * 0.28, y: rect.maxY - w * 0.18), endRadius: w * 0.75, options: [])
    ctx.restoreGState()

    // The net: a cup-shaped rim (open at the top) with its mesh inside.
    let cx = rect.midX
    let cy = rect.minY + w * 0.475
    let R = w * (small ? 0.31 : 0.30)
    let rim = w * (small ? 0.15 : 0.106)
    let chordY = cy + R * 0.5           // height of the rim's two ends (30° and 150°)

    if !small {
        ctx.saveGState()
        let inner = CGMutablePath()
        inner.addEllipse(in: CGRect(x: cx - R, y: cy - R, width: R * 2, height: R * 2))
        ctx.addPath(inner)
        ctx.clip()
        ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: w, height: chordY - rect.minY))
        ctx.setStrokeColor(rgb(1, 1, 1, size >= 128 ? 0.30 : 0.22))
        ctx.setLineWidth(max(1, w * 0.012))
        let step = w * 0.072
        var x = cx - R * 2.2
        while x < cx + R * 2.2 {
            ctx.move(to: CGPoint(x: x, y: cy - R * 1.2)); ctx.addLine(to: CGPoint(x: x + R * 2.4, y: cy + R * 1.2))
            ctx.move(to: CGPoint(x: x, y: cy + R * 1.2)); ctx.addLine(to: CGPoint(x: x + R * 2.4, y: cy - R * 1.2))
            x += step
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    if size >= 64 { ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.012), blur: w * 0.03, color: rgb(0.02, 0.10, 0.30, 0.35)) }
    ctx.setStrokeColor(rgb(1, 1, 1))
    ctx.setLineWidth(rim)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: R, startAngle: .pi * 150 / 180, endAngle: .pi * 30 / 180, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // The catch: a coral play triangle pointing down, dropping into the net.
    let tri = roundedTriangle(top: cy + R * (small ? 0.86 : 0.80), tip: cy - R * 0.40, cx: cx,
                              halfWidth: R * (small ? 0.70 : 0.64), radius: R * 0.16)
    ctx.saveGState()
    if size >= 64 { ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.014), blur: w * 0.035, color: rgb(0.10, 0.05, 0.20, 0.40)) }
    ctx.addPath(tri)
    ctx.setFillColor(rgb(1.0, 0.48, 0.33))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tri)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(1.0, 0.40, 0.36), rgb(1.0, 0.56, 0.30), rgb(1.0, 0.74, 0.25)], [0, 0.45, 1]),
                           start: CGPoint(x: cx, y: cy + R * 0.86), end: CGPoint(x: cx, y: cy - R * 0.40), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make-icons.swift <iconset-dir> <extension-icons-dir> [large-png]"); exit(2) }
let iconset = URL(fileURLWithPath: args[1])
let extIcons = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: extIcons, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
for size in [16, 32, 48, 128] {
    try render(size).write(to: extIcons.appendingPathComponent("icon\(size).png"))
}
if args.count > 3 { try render(1024).write(to: URL(fileURLWithPath: args[3])) }
print("icons written")
