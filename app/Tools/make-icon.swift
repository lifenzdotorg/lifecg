// make-icon: renders the LifeCG app icon (the "plus cluster") and builds Support/AppIcon.icns.
//
//   swiftc app/Tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon app/Support
//
// The four pluses keep the exact sizes, positions and arm proportions of the
// ornaments in the on-air graphic (Sources/LifeCGCore/Resources/plus-layer.png),
// recoloured for a dark tile. Tile geometry follows Apple's macOS icon grid
// (824×824 rounded square inside a 1024×1024 canvas).
import CoreGraphics
import Foundation
import ImageIO

struct Plus {
    enum Style { case solid(CGFloat), outline(CGFloat, width: CGFloat) }   // gray level
    var x: CGFloat, y: CGFloat, size: CGFloat   // top-left, in artwork px
    var arm: CGFloat                            // arm thickness / size
    var style: Style
}

// Measured from plus-layer.png (1920×1080 artwork coordinates, top-left origin).
let pluses: [Plus] = [
    Plus(x: 1771, y: 894, size: 48, arm: 0.44, style: .outline(0.99, width: 0.075)), // outlined
    Plus(x: 1818, y: 887, size: 24, arm: 0.42, style: .solid(0.99)),                 // small solid
    Plus(x: 1837, y: 940, size: 36, arm: 0.44, style: .outline(0.55, width: 0.075)), // faint
    Plus(x: 1786, y: 985, size: 69, arm: 0.42, style: .solid(0.99)),                 // big solid
]

func plusPath(_ r: CGRect, arm: CGFloat) -> CGPath {
    let a = r.width * arm, cx = r.midX, cy = r.midY
    let p = CGMutablePath()
    p.addRect(CGRect(x: cx - a / 2, y: r.minY, width: a, height: r.height))
    p.addRect(CGRect(x: r.minX, y: cy - a / 2, width: r.width, height: a))
    // Union the two bars into one outline so strokes don't cross in the middle.
    return p.union(CGPath(rect: .zero, transform: nil))
}

func render(px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Tile with Apple-grid shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 168, cornerHeight: 168, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(CGColor(gray: 0.14, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    // Subtle top-light gradient so it doesn't look flat in the Dock.
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(gray: 0.20, alpha: 1), CGColor(gray: 0.115, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    // At 16/32 px the outlines vanish, so small sizes use a simplified mark:
    // just the two solid pluses, drawn larger (as Apple does for tiny icons).
    let simple = px <= 32
    let set = simple ? pluses.filter { if case .solid = $0.style { return true } else { return false } } : pluses
    // Fit the cluster bbox into the tile.
    let bx0 = set.map(\.x).min()!, by0 = set.map(\.y).min()!
    let bw = set.map { $0.x + $0.size }.max()! - bx0, bh = set.map { $0.y + $0.size }.max()! - by0
    let scale = 824 * (simple ? 0.70 : 0.72) / bh
    let ox = 512 - bw * scale / 2 + (simple ? 0 : 6)   // optical centring: big plus carries the weight
    let oy = 512 + bh * scale / 2                      // top edge (CG y-up)
    for p in set {
        let r = CGRect(x: ox + (p.x - bx0) * scale, y: oy - (p.y - by0 + p.size) * scale,
                       width: p.size * scale, height: p.size * scale)
        switch p.style {
        case .solid(let g):
            ctx.addPath(plusPath(r, arm: p.arm)); ctx.setFillColor(CGColor(gray: g, alpha: 1)); ctx.fillPath()
        case .outline(let g, let w):
            let lw = p.size * scale * w
            ctx.addPath(plusPath(r.insetBy(dx: lw / 2, dy: lw / 2), arm: p.arm))
            ctx.setStrokeColor(CGColor(gray: g, alpha: 1)); ctx.setLineWidth(lw); ctx.setLineJoin(.miter)
            ctx.strokePath()
        }
    }
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    precondition(CGImageDestinationFinalize(d))
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(render(px: 1024), outDir.appendingPathComponent("AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")
try? FileManager.default.removeItem(at: iconset)
print("wrote \(outDir.path)/AppIcon.icns and AppIcon-1024.png")
