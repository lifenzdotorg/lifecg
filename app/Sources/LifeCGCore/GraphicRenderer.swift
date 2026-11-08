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

/// How the graphic animates on or off (chosen separately for each direction).
public enum Transition: String, Codable, CaseIterable, Sendable {
    /// Bars wipe in from the right, then the text fades in (the original NodeCG look).
    case slideBoxFadeText
    /// Bars slide out from behind the plus ornaments with their text already on them.
    case slideBoxAndText
    /// The whole graphic fades.
    case fade
    /// Instant.
    case cut

    public var label: String {
        switch self {
        case .slideBoxFadeText: return "Slide box, fade text"
        case .slideBoxAndText: return "Slide box and text"
        case .fade: return "Fade"
        case .cut: return "Cut"
        }
    }

    /// Seconds for a full sweep (0 = instant).
    public var duration: Double {
        switch self {
        case .slideBoxFadeText: return 0.9
        case .slideBoxAndText: return 0.75
        case .fade: return 0.5
        case .cut: return 0
        }
    }
}

/// Where everything sits for one title. CoreGraphics coordinates (origin bottom-left,
/// y up), before `GraphicStyle.offsetX/Y` is applied.
public struct GraphicLayout {
    public let titleBox: CGRect
    public let titleLine: CTLine
    public let titleTextOrigin: CGPoint
    public let desigBox: CGRect?
    public let desigLine: CTLine?
    public let desigTextOrigin: CGPoint
}

/// Per-frame animation values for one progress/transition, shared by the CPU renderer
/// and the GPU compositor so they can't drift apart.
public struct FramePlan {
    public struct Piece {
        public var visible: Bool
        public var clip: CGRect      // screen space (CG coords, before offset)
        public var dx: Double        // horizontal slide of the content
        public var textAlpha: Double
    }
    public var gradientAlpha = 1.0
    public var plusAlpha = 1.0
    public var plusShift = 0.0
    /// Fade transition: alpha applied to the whole composite (1 = no fade).
    public var globalAlpha = 1.0
    public var title: Piece
    public var desig: Piece
    /// True when this frame is exactly the finished graphic (progress 1 or a cut).
    public var isComplete = false
}

/// Renders the lower third into a 1920×1080 premultiplied BGRA bitmap (CPU path, used
/// for stills, tests and as the reference), and rasterises the separate pieces that the
/// GPU compositor animates in real time.
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
        /// Room around a box for its drop shadow when rasterised as a piece.
        static let shadowMargin = 40.0
    }

    static let titleBoxColor = CGColor(srgbRed: 0.992, green: 0.992, blue: 0.992, alpha: 0.91)
    static let desigBoxColor = CGColor(srgbRed: 0.141, green: 0.141, blue: 0.141, alpha: 0.93)
    static let titleTextColor = CGColor(srgbRed: 0.133, green: 0.133, blue: 0.133, alpha: 1)
    static let desigTextColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    public var style: GraphicStyle { didSet { fontCache.removeAll() } }

    public let context: CGContext
    let plusLayer: CGImage?
    let gradientLayer: CGImage?
    private var fontCache: [String: CTFont] = [:]

    public init(style: GraphicStyle = GraphicStyle()) {
        self.style = style
        context = Self.makeContext(width: Self.width, height: Self.height)
        plusLayer = Self.loadImage("plus-layer")
        gradientLayer = Self.loadImage("gradient-layer")
    }

    static func makeContext(width: Int, height: Int) -> CGContext {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        c.interpolationQuality = .high
        return c
    }

    /// Raw BGRA bytes (premultiplied), rows top-to-bottom, `width*4` bytes per row.
    public var bytes: UnsafeMutableRawPointer { context.data! }
    public var bytesPerRow: Int { context.bytesPerRow }

    public func makeImage() -> CGImage? { context.makeImage() }

    /// Names of the fonts actually in use (for the UI, so operators can see a fallback).
    /// Doesn't touch the font cache, so it's safe to call from any thread.
    public func resolvedFontNames() -> (title: String, designation: String) {
        (CTFontCopyPostScriptName(Self.resolveFont(style.titleFonts)) as String,
         CTFontCopyPostScriptName(Self.resolveFont(style.designationFonts)) as String)
    }

    // MARK: - Layout and frame plan

    public func layout(title: String, designation: String) -> GraphicLayout {
        let tLine = makeLine(title, fonts: style.titleFonts, cap: style.titleCapHeight, tracking: style.titleTracking,
                             color: Self.titleTextColor,
                             maxInkWidth: G.titleBoxRight - G.titlePadRight - G.titlePadLeft - G.minLeft)
        let tInk = CTLineGetImageBounds(tLine, nil)
        let tBox = rect(left: G.titleBoxRight - G.titlePadRight - tInk.width - G.titlePadLeft,
                        top: G.titleBoxTop, right: G.titleBoxRight, bottom: G.titleBoxBottom)
        let tOrigin = CGPoint(x: G.titleBoxRight - G.titlePadRight - tInk.maxX, y: cgY(G.titleBaseline))

        var dBox: CGRect?, dLine: CTLine?, dOrigin = CGPoint.zero
        if !designation.isEmpty {
            let l = makeLine(designation, fonts: style.designationFonts, cap: style.designationCapHeight,
                             tracking: style.designationTracking, color: Self.desigTextColor,
                             maxInkWidth: G.desigBoxRight - G.desigPadRight - G.desigPadLeft - G.minLeft)
            let ink = CTLineGetImageBounds(l, nil)
            dLine = l
            dBox = rect(left: G.desigBoxRight - G.desigPadRight - ink.width - G.desigPadLeft,
                        top: G.desigBoxTop, right: G.desigBoxRight, bottom: G.desigBoxBottom)
            dOrigin = CGPoint(x: G.desigBoxRight - G.desigPadRight - ink.maxX, y: cgY(G.desigBaseline))
        }
        return GraphicLayout(titleBox: tBox, titleLine: tLine, titleTextOrigin: tOrigin,
                             desigBox: dBox, desigLine: dLine, desigTextOrigin: dOrigin)
    }

    /// Animation values for `progress` (0 hidden … 1 shown) under `transition`.
    public static func plan(_ layout: GraphicLayout, progress: Double, transition: Transition) -> FramePlan {
        let p = transition == .cut ? 1 : min(max(progress, 0), 1)
        var gradA = 1.0, plusA = 1.0, titleR = 1.0, desigR = 1.0, textA = 1.0
        var titleS = 0.0, desigS = 0.0, plusShift = 0.0, globalA = 1.0
        switch transition {
        case .slideBoxFadeText:
            gradA = ease(seg(p, 0.0, 0.5))
            plusA = ease(seg(p, 0.1, 0.55)); plusShift = (1 - plusA) * 24
            titleR = easeOutCubic(seg(p, 0.15, 0.7))
            desigR = easeOutCubic(seg(p, 0.3, 0.85))
            textA = seg(p, 0.45, 1.0)
        case .slideBoxAndText:
            gradA = ease(seg(p, 0.0, 0.5))
            plusA = ease(seg(p, 0.0, 0.4)); plusShift = (1 - plusA) * 24
            titleS = 1 - easeOutCubic(seg(p, 0.1, 0.8))
            desigS = 1 - easeOutCubic(seg(p, 0.25, 1.0))
        case .fade:
            globalA = ease(p)
        case .cut:
            break
        }
        func piece(_ box: CGRect, reveal: Double, slide: Double) -> FramePlan.Piece {
            let clip = slide > 0 ? slideClip(box) : revealRect(box, reveal)
            return .init(visible: reveal > 0 && slide < 1, clip: clip, dx: slide * (box.width + 24), textAlpha: textA)
        }
        let t = piece(layout.titleBox, reveal: titleR, slide: titleS)
        let d = layout.desigBox.map { piece($0, reveal: desigR, slide: desigS) }
            ?? .init(visible: false, clip: .zero, dx: 0, textAlpha: 0)
        var plan = FramePlan(title: t, desig: d)
        plan.gradientAlpha = gradA
        plan.plusAlpha = plusA
        plan.plusShift = plusShift
        plan.globalAlpha = globalA
        plan.isComplete = p >= 1
        return plan
    }

    // MARK: - CPU rendering

    /// Draw one frame on the CPU.
    /// - Parameters:
    ///   - title: nil or empty → transparent frame.
    ///   - progress: 0 = fully hidden, 1 = fully revealed. Animations sweep this.
    ///   - transition: the look of the in-between frames. Every transition draws the
    ///     same frame at progress 1, and nothing at 0.
    public func render(title: String?, designation: String, progress: Double, transition: Transition = .slideBoxFadeText) {
        let ctx = context
        ctx.clear(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        guard let title, !title.isEmpty, progress > 0 else { return }
        let lay = layout(title: title, designation: designation)
        let plan = Self.plan(lay, progress: progress, transition: transition)

        ctx.saveGState()
        ctx.translateBy(x: style.offsetX, y: -style.offsetY)
        if plan.globalAlpha < 1 {
            ctx.setAlpha(plan.globalAlpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // fade the composite, not each layer
        }
        let full = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        if let gradientLayer, plan.gradientAlpha > 0 {
            ctx.saveGState(); ctx.setAlpha(plan.gradientAlpha); ctx.draw(gradientLayer, in: full); ctx.restoreGState()
        }
        drawPiece(ctx, plan.title, box: lay.titleBox, color: Self.titleBoxColor, line: lay.titleLine, origin: lay.titleTextOrigin)
        if let dBox = lay.desigBox, let dLine = lay.desigLine {
            drawPiece(ctx, plan.desig, box: dBox, color: Self.desigBoxColor, line: dLine, origin: lay.desigTextOrigin)
        }
        if let plusLayer, plan.plusAlpha > 0 {
            ctx.saveGState()
            ctx.setAlpha(plan.plusAlpha)
            ctx.translateBy(x: plan.plusShift, y: 0)
            ctx.draw(plusLayer, in: full)
            ctx.restoreGState()
        }
        if plan.globalAlpha < 1 { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    private func drawPiece(_ ctx: CGContext, _ piece: FramePlan.Piece, box: CGRect, color: CGColor, line: CTLine, origin: CGPoint) {
        guard piece.visible else { return }
        ctx.saveGState()
        ctx.clip(to: piece.clip)
        ctx.translateBy(x: piece.dx, y: 0)
        Self.drawBox(ctx, box, color: color)
        if piece.textAlpha > 0 {
            ctx.setAlpha(piece.textAlpha)
            ctx.textPosition = origin
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    static func drawBox(_ ctx: CGContext, _ box: CGRect, color: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: CGColor(gray: 0, alpha: 0.22))
        ctx.setFillColor(color)
        ctx.fill(box)
        ctx.restoreGState()
    }

    // MARK: - Pieces for the GPU compositor

    /// A rasterised piece of the graphic: premultiplied BGRA image placed at `rect`
    /// (CG coordinates, before offset).
    public struct Sprite {
        public let image: CGImage
        public let rect: CGRect
    }

    public struct SpriteSet {
        public let layout: GraphicLayout
        public let titleBox: Sprite
        public let titleText: Sprite
        public let desigBox: Sprite?
        public let desigText: Sprite?
    }

    /// Rasterise one title's boxes and text once; the compositor then animates them on the GPU.
    public func sprites(title: String, designation: String) -> SpriteSet {
        let lay = layout(title: title, designation: designation)
        func boxSprite(_ box: CGRect, _ color: CGColor) -> Sprite {
            let r = box.insetBy(dx: -G.shadowMargin, dy: -G.shadowMargin).integral
            return Self.rasterize(r) { ctx in Self.drawBox(ctx, box, color: color) }
        }
        func textSprite(_ line: CTLine, _ origin: CGPoint) -> Sprite {
            let ink = CTLineGetImageBounds(line, nil)
            let r = ink.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -4).integral
            return Self.rasterize(r) { ctx in ctx.textPosition = origin; CTLineDraw(line, ctx) }
        }
        return SpriteSet(
            layout: lay,
            titleBox: boxSprite(lay.titleBox, Self.titleBoxColor),
            titleText: textSprite(lay.titleLine, lay.titleTextOrigin),
            desigBox: lay.desigBox.map { boxSprite($0, Self.desigBoxColor) },
            desigText: lay.desigLine.map { textSprite($0, lay.desigTextOrigin) })
    }

    /// Draw into a bitmap covering `rect` (integral, CG coords), using screen coordinates.
    static func rasterize(_ rect: CGRect, _ draw: (CGContext) -> Void) -> Sprite {
        let ctx = makeContext(width: max(Int(rect.width), 1), height: max(Int(rect.height), 1))
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        draw(ctx)
        return Sprite(image: ctx.makeImage()!, rect: rect)
    }

    /// Encode the current frame as PNG.
    public func pngData() -> Data? {
        guard let img = makeImage() else { return nil }
        return Self.png(img)
    }

    public static func png(_ img: CGImage) -> Data? {
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

    /// While sliding, content is masked at the box's right edge so it appears to emerge
    /// from behind the plus ornaments (shadow room kept on the other sides).
    static func slideClip(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX - 30, y: box.minY - 30, width: box.width + 30, height: box.height + 60)
    }

    /// Wipe in from the right edge.
    static func revealRect(_ r: CGRect, _ amount: Double) -> CGRect {
        let w = (r.width + 20) * amount
        return CGRect(x: r.maxX - w, y: r.minY - 30, width: w + 30, height: r.height + 60)
    }

    static func seg(_ p: Double, _ a: Double, _ b: Double) -> Double { min(max((p - a) / (b - a), 0), 1) }
    static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    static func resolveFont(_ names: [String]) -> CTFont {
        for name in names {
            let f = CTFontCreateWithName(name as CFString, 100, nil)
            if (CTFontCopyPostScriptName(f) as String) == name { return f }
        }
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, 100, nil)!
    }

    private func font(_ names: [String], cap: Double) -> CTFont {
        let key = names.joined(separator: ",") + "@\(cap)"
        if let f = fontCache[key] { return f }
        let base = Self.resolveFont(names)
        let capRatio = max(CTFontGetCapHeight(base) / 100, 0.1)
        let sized = CTFontCreateCopyWithAttributes(base, cap / capRatio, nil, nil)
        fontCache[key] = sized
        return sized
    }

    private func makeLine(_ s: String, fonts: [String], cap: Double, tracking: Double, color: CGColor,
                          maxInkWidth: Double) -> CTLine {
        func build(_ cap: Double) -> CTLine {
            let f = font(fonts, cap: cap)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking * CTFontGetSize(f),
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        }
        let line = build(cap)
        let w = CTLineGetImageBounds(line, nil).width
        // Shrink to fit very long names rather than running off screen.
        return (w > maxInkWidth && w > 0) ? build(cap * maxInkWidth / w * 0.995) : line
    }

    static func loadImage(_ name: String) -> CGImage? {
        guard let url = Resources.url(name, ext: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
