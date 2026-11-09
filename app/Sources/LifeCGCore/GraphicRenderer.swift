import CoreGraphics
import CoreText
import Foundation
import ImageIO

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
    public let anchor: Theme.Anchor
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
/// GPU compositor animates in real time. All geometry, colours and fonts come from the
/// current `Theme`.
public final class GraphicRenderer {
    public static let width = 1920
    public static let height = 1080
    /// Room around a box for its drop shadow when rasterised as a piece.
    static let shadowMargin = 40.0

    public var theme: LoadedTheme { didSet { fontCache.removeAll() } }
    /// Nudge the whole graphic (px, +x right, +y down). Operator setting, not part of the theme.
    public var offset: CGPoint = .zero

    public let context: CGContext
    var backgroundLayer: CGImage? { theme.background }
    var foregroundLayer: CGImage? { theme.foreground }
    private var fontCache: [String: CTFont] = [:]

    public init(theme: LoadedTheme = .builtInLife) {
        self.theme = theme
        context = Self.makeContext(width: Self.width, height: Self.height)
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
        let t = theme.theme
        return (CTFontCopyPostScriptName(Self.resolveFont(t.title.fonts)) as String,
                CTFontCopyPostScriptName(Self.resolveFont((t.designation ?? t.title).fonts)) as String)
    }

    /// True when the first font listed for each bar is installed (no fallback in use).
    public func preferredFontsInstalled() -> Bool {
        let t = theme.theme
        let names = [t.title.fonts.first, t.designation?.fonts.first].compactMap { $0 }
        return names.allSatisfy { (CTFontCopyPostScriptName(CTFontCreateWithName($0 as CFString, 12, nil)) as String) == $0 }
    }

    // MARK: - Layout and frame plan

    /// Box and text placement for one bar holding `text`.
    func barLayout(_ bar: Theme.Bar, text: String, anchor: Theme.Anchor, edgeMargin: Double)
        -> (box: CGRect, line: CTLine, origin: CGPoint) {
        let W = Double(Self.width)
        let maxInk = anchor == .right
            ? bar.anchorX - bar.padOuter - bar.padInner - edgeMargin
            : (W - edgeMargin) - bar.anchorX - bar.padOuter - bar.padInner
        let line = makeLine(bar.uppercase ? text.uppercased() : text, fonts: bar.fonts, cap: bar.capHeight,
                            tracking: bar.tracking, color: .hex(bar.textColor), maxInkWidth: max(maxInk, 50))
        let ink = CTLineGetImageBounds(line, nil)
        let width = bar.padOuter + ink.width + bar.padInner
        let left = anchor == .right ? bar.anchorX - width : bar.anchorX
        let box = rect(left: left, top: bar.top, right: left + width, bottom: bar.bottom)
        let originX = anchor == .right ? bar.anchorX - bar.padOuter - ink.maxX : bar.anchorX + bar.padOuter - ink.minX
        return (box, line, CGPoint(x: originX, y: cgY(bar.baseline)))
    }

    public func layout(title: String, designation: String) -> GraphicLayout {
        let t = theme.theme
        let tl = barLayout(t.title, text: title, anchor: t.anchor, edgeMargin: t.edgeMargin)
        var dBox: CGRect?, dLine: CTLine?, dOrigin = CGPoint.zero
        if !designation.isEmpty, let bar = t.designation {
            let dl = barLayout(bar, text: designation, anchor: t.anchor, edgeMargin: t.edgeMargin)
            dBox = dl.box; dLine = dl.line; dOrigin = dl.origin
        }
        return GraphicLayout(anchor: t.anchor, titleBox: tl.box, titleLine: tl.line, titleTextOrigin: tl.origin,
                             desigBox: dBox, desigLine: dLine, desigTextOrigin: dOrigin)
    }

    /// Animation values for `progress` (0 hidden … 1 shown) under `transition`.
    public static func plan(_ layout: GraphicLayout, progress: Double, transition: Transition) -> FramePlan {
        let p = transition == .cut ? 1 : min(max(progress, 0), 1)
        var gradA = 1.0, plusA = 1.0, titleR = 1.0, desigR = 1.0, textA = 1.0
        var titleS = 0.0, desigS = 0.0, plusShift = 0.0, globalA = 1.0
        let side: Double = layout.anchor == .right ? 1 : -1   // motion comes from the anchored side
        switch transition {
        case .slideBoxFadeText:
            gradA = ease(seg(p, 0.0, 0.5))
            plusA = ease(seg(p, 0.1, 0.55)); plusShift = (1 - plusA) * 24 * side
            titleR = easeOutCubic(seg(p, 0.15, 0.7))
            desigR = easeOutCubic(seg(p, 0.3, 0.85))
            textA = seg(p, 0.45, 1.0)
        case .slideBoxAndText:
            gradA = ease(seg(p, 0.0, 0.5))
            plusA = ease(seg(p, 0.0, 0.4)); plusShift = (1 - plusA) * 24 * side
            titleS = 1 - easeOutCubic(seg(p, 0.1, 0.8))
            desigS = 1 - easeOutCubic(seg(p, 0.25, 1.0))
        case .fade:
            globalA = ease(p)
        case .cut:
            break
        }
        func piece(_ box: CGRect, reveal: Double, slide: Double) -> FramePlan.Piece {
            let clip = slide > 0 ? slideClip(box, layout.anchor) : revealRect(box, reveal, layout.anchor)
            return .init(visible: reveal > 0 && slide < 1, clip: clip, dx: slide * (box.width + 24) * side, textAlpha: textA)
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
        ctx.translateBy(x: offset.x, y: -offset.y)
        if plan.globalAlpha < 1 {
            ctx.setAlpha(plan.globalAlpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // fade the composite, not each layer
        }
        let full = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        if let backgroundLayer, plan.gradientAlpha > 0 {
            ctx.saveGState(); ctx.setAlpha(plan.gradientAlpha); ctx.draw(backgroundLayer, in: full); ctx.restoreGState()
        }
        let t = theme.theme
        drawPiece(ctx, plan.title, box: lay.titleBox, bar: t.title, line: lay.titleLine, origin: lay.titleTextOrigin)
        if let dBox = lay.desigBox, let dLine = lay.desigLine, let bar = t.designation {
            drawPiece(ctx, plan.desig, box: dBox, bar: bar, line: dLine, origin: lay.desigTextOrigin)
        }
        if let foregroundLayer, plan.plusAlpha > 0 {
            ctx.saveGState()
            ctx.setAlpha(plan.plusAlpha)
            ctx.translateBy(x: plan.plusShift, y: 0)
            ctx.draw(foregroundLayer, in: full)
            ctx.restoreGState()
        }
        if plan.globalAlpha < 1 { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    private func drawPiece(_ ctx: CGContext, _ piece: FramePlan.Piece, box: CGRect, bar: Theme.Bar, line: CTLine, origin: CGPoint) {
        guard piece.visible else { return }
        ctx.saveGState()
        ctx.clip(to: piece.clip)
        ctx.translateBy(x: piece.dx, y: 0)
        Self.drawBox(ctx, box, bar: bar)
        if piece.textAlpha > 0 {
            ctx.setAlpha(piece.textAlpha)
            ctx.textPosition = origin
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    static func drawBox(_ ctx: CGContext, _ box: CGRect, bar: Theme.Bar) {
        ctx.saveGState()
        if let sh = bar.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -sh.offsetY), blur: sh.blur, color: CGColor(gray: 0, alpha: sh.opacity))
        }
        ctx.setFillColor(.hex(bar.color))
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
        let t = theme.theme
        func boxSprite(_ box: CGRect, _ bar: Theme.Bar) -> Sprite {
            let r = box.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin).integral
            return Self.rasterize(r) { ctx in Self.drawBox(ctx, box, bar: bar) }
        }
        func textSprite(_ line: CTLine, _ origin: CGPoint) -> Sprite {
            let ink = CTLineGetImageBounds(line, nil)
            let r = ink.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -4).integral
            return Self.rasterize(r) { ctx in ctx.textPosition = origin; CTLineDraw(line, ctx) }
        }
        return SpriteSet(
            layout: lay,
            titleBox: boxSprite(lay.titleBox, t.title),
            titleText: textSprite(lay.titleLine, lay.titleTextOrigin),
            desigBox: lay.desigBox.flatMap { box in t.designation.map { boxSprite(box, $0) } },
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
    static func slideClip(_ box: CGRect, _ anchor: Theme.Anchor) -> CGRect {
        anchor == .right
            ? CGRect(x: box.minX - 30, y: box.minY - 30, width: box.width + 30, height: box.height + 60)
            : CGRect(x: box.minX, y: box.minY - 30, width: box.width + 30, height: box.height + 60)
    }

    /// Wipe in from the anchored edge.
    static func revealRect(_ r: CGRect, _ amount: Double, _ anchor: Theme.Anchor) -> CGRect {
        let w = (r.width + 20) * amount
        return anchor == .right
            ? CGRect(x: r.maxX - w, y: r.minY - 30, width: w + 30, height: r.height + 60)
            : CGRect(x: r.minX - 30, y: r.minY - 30, width: w + 30, height: r.height + 60)
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

}
