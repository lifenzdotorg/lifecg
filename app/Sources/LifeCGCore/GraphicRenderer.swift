import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Look of the lower third. Defaults reproduce the original LIFE NodeCG graphic
/// (measured from docs/reference-composite.png at 1920×1080).
public struct GraphicStyle: Codable, Equatable, Sendable {
    /// PostScript names, tried in order. Neuzeit Grotesk is the brand font; it is
    /// commercial so it is NOT bundled — install it on the CG Mac.
    public var titleFonts = ["NeuzeitGro-Bol", "NeuzeitGrotesk-Bold", "AvenirNext-Bold", "HelveticaNeue-Bold"]
    public var designationFonts = ["NeuzeitGro-Reg", "NeuzeitGrotesk-Regular", "AvenirNext-Regular", "HelveticaNeue"]
    /// Text is sized by cap height (px) so fallback fonts keep the same visual size.
    public var titleCapHeight: Double = 39.5
    public var designationCapHeight: Double = 23.5
    /// Letter spacing in em.
    public var titleTracking: Double = 0.0675
    public var designationTracking: Double = 0.0923
    /// Nudge the whole graphic (px, +x right, +y down).
    public var offsetX: Double = 0
    public var offsetY: Double = 0

    public init() {}
}

/// Renders the lower third into a 1920×1080 premultiplied BGRA bitmap.
public final class GraphicRenderer {
    public static let width = 1920
    public static let height = 1080

    // Geometry in top-left pixel coordinates (from the reference composite).
    enum G {
        static let titleBoxRight = 1795.0, titleBoxTop = 918.0, titleBoxBottom = 993.0
        static let titlePadLeft = 23.0, titlePadRight = 26.0, titleBaseline = 972.5
        static let desigBoxRight = 1806.0, desigBoxTop = 993.0, desigBoxBottom = 1047.0
        static let desigPadLeft = 30.0, desigPadRight = 53.0, desigBaseline = 1030.5
        static let minLeft = 40.0
    }

    public var style: GraphicStyle { didSet { fontCache.removeAll() } }

    public let context: CGContext
    private let plusLayer: CGImage?
    private let gradientLayer: CGImage?
    private var fontCache: [String: CTFont] = [:]

    public init(style: GraphicStyle = GraphicStyle()) {
        self.style = style
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        context = CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8,
                            bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: info)!
        context.interpolationQuality = .high
        plusLayer = Self.loadImage("plus-layer")
        gradientLayer = Self.loadImage("gradient-layer")
    }

    /// Raw BGRA bytes (premultiplied), rows top-to-bottom, `width*4` bytes per row.
    public var bytes: UnsafeMutableRawPointer { context.data! }
    public var bytesPerRow: Int { context.bytesPerRow }

    public func makeImage() -> CGImage? { context.makeImage() }

    /// Names of the fonts actually in use (for the UI, so operators can see a fallback).
    public func resolvedFontNames() -> (title: String, designation: String) {
        (CTFontCopyPostScriptName(font(style.titleFonts, cap: 40)) as String,
         CTFontCopyPostScriptName(font(style.designationFonts, cap: 40)) as String)
    }

    /// Draw one frame.
    /// - Parameters:
    ///   - entry: what to draw (nil → transparent frame).
    ///   - progress: 0 = fully hidden, 1 = fully revealed. Animations sweep this.
    public func render(title: String?, designation: String, progress: Double) {
        let ctx = context
        ctx.clear(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        guard let title, !title.isEmpty, progress > 0 else { return }
        let p = min(max(progress, 0), 1)

        ctx.saveGState()
        ctx.translateBy(x: style.offsetX, y: -style.offsetY)

        // Phase timings within p ∈ [0,1].
        let gradA = ease(seg(p, 0.0, 0.5))
        let plusA = ease(seg(p, 0.1, 0.55))
        let titleR = easeOutCubic(seg(p, 0.15, 0.7))
        let desigR = easeOutCubic(seg(p, 0.3, 0.85))
        let textA = seg(p, 0.45, 1.0)

        let full = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        if let gradientLayer, gradA > 0 {
            ctx.saveGState(); ctx.setAlpha(gradA); ctx.draw(gradientLayer, in: full); ctx.restoreGState()
        }

        // --- Title box ---
        let tLine = makeLine(title, fonts: style.titleFonts, cap: style.titleCapHeight,
                             tracking: style.titleTracking, color: CGColor(srgbRed: 0.133, green: 0.133, blue: 0.133, alpha: 1),
                             maxInkWidth: G.titleBoxRight - G.titlePadRight - G.titlePadLeft - G.minLeft)
        let tInk = CTLineGetImageBounds(tLine.line, nil)
        let tBoxLeft = G.titleBoxRight - G.titlePadRight - tInk.width - G.titlePadLeft
        let tBox = rect(left: tBoxLeft, top: G.titleBoxTop, right: G.titleBoxRight, bottom: G.titleBoxBottom)
        if titleR > 0 {
            let clip = revealRect(tBox, titleR)
            ctx.saveGState()
            ctx.clip(to: clip)
            shadow(ctx)
            ctx.setFillColor(CGColor(srgbRed: 0.992, green: 0.992, blue: 0.992, alpha: 0.91))
            ctx.fill(tBox)
            ctx.restoreGState()
            if textA > 0 {
                ctx.saveGState(); ctx.clip(to: clip); ctx.setAlpha(textA)
                let x = G.titleBoxRight - G.titlePadRight - tInk.maxX
                ctx.textPosition = CGPoint(x: x, y: cgY(G.titleBaseline))
                CTLineDraw(tLine.line, ctx)
                ctx.restoreGState()
            }
        }

        // --- Designation box (only when there is text) ---
        if !designation.isEmpty, desigR > 0 {
            let dLine = makeLine(designation, fonts: style.designationFonts, cap: style.designationCapHeight,
                                 tracking: style.designationTracking, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                 maxInkWidth: G.desigBoxRight - G.desigPadRight - G.desigPadLeft - G.minLeft)
            let dInk = CTLineGetImageBounds(dLine.line, nil)
            let dBoxLeft = G.desigBoxRight - G.desigPadRight - dInk.width - G.desigPadLeft
            let dBox = rect(left: dBoxLeft, top: G.desigBoxTop, right: G.desigBoxRight, bottom: G.desigBoxBottom)
            let clip = revealRect(dBox, desigR)
            ctx.saveGState()
            ctx.clip(to: clip)
            shadow(ctx)
            ctx.setFillColor(CGColor(srgbRed: 0.141, green: 0.141, blue: 0.141, alpha: 0.93))
            ctx.fill(dBox)
            ctx.restoreGState()
            if textA > 0 {
                ctx.saveGState(); ctx.clip(to: clip); ctx.setAlpha(textA)
                let x = G.desigBoxRight - G.desigPadRight - dInk.maxX
                ctx.textPosition = CGPoint(x: x, y: cgY(G.desigBaseline))
                CTLineDraw(dLine.line, ctx)
                ctx.restoreGState()
            }
        }

        // --- Plus ornaments on top ---
        if let plusLayer, plusA > 0 {
            ctx.saveGState()
            ctx.setAlpha(plusA)
            ctx.translateBy(x: (1 - plusA) * 24, y: 0)
            ctx.draw(plusLayer, in: full)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Encode the current frame as PNG.
    public func pngData() -> Data? {
        guard let img = makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Helpers

    private func cgY(_ topY: Double) -> Double { Double(Self.height) - topY }

    private func rect(left: Double, top: Double, right: Double, bottom: Double) -> CGRect {
        CGRect(x: left, y: cgY(bottom), width: right - left, height: bottom - top)
    }

    /// Wipe in from the right edge.
    private func revealRect(_ r: CGRect, _ amount: Double) -> CGRect {
        let w = (r.width + 20) * amount
        return CGRect(x: r.maxX - w, y: r.minY - 30, width: w + 30, height: r.height + 60)
    }

    private func shadow(_ ctx: CGContext) {
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: CGColor(gray: 0, alpha: 0.22))
    }

    private func seg(_ p: Double, _ a: Double, _ b: Double) -> Double { min(max((p - a) / (b - a), 0), 1) }
    private func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func font(_ names: [String], cap: Double) -> CTFont {
        let key = names.joined(separator: ",") + "@\(cap)"
        if let f = fontCache[key] { return f }
        var chosen: CTFont?
        for name in names {
            let f = CTFontCreateWithName(name as CFString, 100, nil)
            if (CTFontCopyPostScriptName(f) as String) == name { chosen = f; break }
        }
        let base = chosen ?? CTFontCreateUIFontForLanguage(.emphasizedSystem, 100, nil)!
        let capRatio = max(CTFontGetCapHeight(base) / 100, 0.1)
        let sized = CTFontCreateCopyWithAttributes(base, cap / capRatio, nil, nil)
        fontCache[key] = sized
        return sized
    }

    private func makeLine(_ s: String, fonts: [String], cap: Double, tracking: Double, color: CGColor,
                          maxInkWidth: Double) -> (line: CTLine, font: CTFont) {
        func build(_ cap: Double) -> (CTLine, CTFont) {
            let f = font(fonts, cap: cap)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking * CTFontGetSize(f),
            ]
            return (CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), f)
        }
        var (line, f) = build(cap)
        let w = CTLineGetImageBounds(line, nil).width
        if w > maxInkWidth, w > 0 {
            // Shrink to fit very long names rather than running off screen.
            (line, f) = build(cap * maxInkWidth / w * 0.995)
        }
        return (line, f)
    }

    private static func loadImage(_ name: String) -> CGImage? {
        guard let url = Resources.url(name, ext: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
