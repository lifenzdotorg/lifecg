import CoreGraphics
import CoreText
import Foundation

/// Draws speaker-notes slides with CoreText, following the theme rules in docs/notes-platform/FORMAT.md.
/// Thread-safe: no shared mutable state.
public enum NotesRenderer {
    public static let width = GraphicRenderer.width
    public static let height = GraphicRenderer.height

    /// Calibrated against ProPresenter 7 renders of the same themes (Oct 2026 Central deck):
    /// PP lays text out with TextKit, which pads each line 5 pt left and right, and keeps
    /// descent + leading + 5 pt below the last baseline. Line pitch = natural height × lineHeight.
    static let sidePadding = 5.0
    static let bottomInset = 5.0
    static let fallbackRegular = "AvenirNext-Regular"
    static let fallbackBold = "AvenirNext-Bold"

    // MARK: Fonts

    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var fontCache: [String: CTFont] = [:]

    static func font(_ name: String, size: Double, bold: Bool) -> CTFont {
        let key = "\(name)@\(size)"
        fontLock.lock(); defer { fontLock.unlock() }
        if let f = fontCache[key] { return f }
        var f = CTFontCreateWithName(name as CFString, size, nil)
        if (CTFontCopyPostScriptName(f) as String) != name {
            f = CTFontCreateWithName((bold ? fallbackBold : fallbackRegular) as CFString, size, nil)
        }
        fontCache[key] = f
        return f
    }

    /// True when the theme's own fonts are installed (else Avenir Next stands in).
    public static func fontsInstalled(_ t: NotesTheme) -> Bool {
        t.styles.values.allSatisfy { s in
            [s.regularFont, s.boldFont].allSatisfy {
                (CTFontCopyPostScriptName(CTFontCreateWithName($0 as CFString, 12, nil)) as String) == $0
            }
        }
    }

    // MARK: Layout

    public struct Line {
        public let line: CTLine
        public let baselineFromTop: Double   // relative to the text block's top
    }

    public struct Layout {
        public let lines: [Line]
        public let blockHeight: Double
        public let style: NotesTheme.Style
        public var lineCount: Int { lines.count }
        /// Top of the text block in canvas coordinates (y down).
        public var top: Double {
            let r = style.cgRect
            switch style.valign {
            case "top": return r.minY
            case "middle": return r.midY - blockHeight / 2
            default: return r.maxY - blockHeight
            }
        }
    }

    static func attributes(_ font: CTFont, _ style: NotesTheme.Style, _ look: NotesTheme.TextLook, strokePass: Bool) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CSSColor.parse(look.color),
            NSAttributedString.Key(kCTKernAttributeName as String): style.tracking,
        ]
        if strokePass, let p = look.strokePercent, p != 0 {
            // Outline pass, drawn under the fill: only the outer half of the stroke shows, so the
            // glyphs keep their weight (matches ProPresenter's look better than Cocoa fill+stroke).
            a[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = abs(p) * 2
            a[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CSSColor.parse(look.strokeColor ?? "rgba(0,0,0,0.3)")
        }
        return a
    }

    /// Break a slide into lines inside its style's width. `\n` is a hard break; U+00A0 never breaks.
    public static func layout(_ slide: NoteSlide, theme: NotesTheme, strokePass: Bool = false) -> Layout {
        let style = theme.style(slide.style)
        let reg = font(style.regularFont, size: style.size, bold: false)
        let bold = font(style.boldFont, size: style.size, bold: true)

        // Split runs into paragraphs at hard breaks.
        var paragraphs: [NSMutableAttributedString] = [NSMutableAttributedString()]
        for run in slide.runs {
            let attrs = attributes(run.isBold ? bold : reg, style, theme.text, strokePass: strokePass)
            let parts = run.t.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { paragraphs.append(NSMutableAttributedString()) }
                if !part.isEmpty { paragraphs[paragraphs.count - 1].append(NSAttributedString(string: part, attributes: attrs)) }
            }
        }

        let ascent = Double(CTFontGetAscent(reg)), descent = Double(CTFontGetDescent(reg)), leading = Double(CTFontGetLeading(reg))
        let advance = (ascent + descent + leading) * style.lineHeight
        let width = Double(style.cgRect.width) - sidePadding * 2
        var lines: [Line] = []
        for p in paragraphs {
            if p.length == 0 {   // empty paragraph: blank line
                lines.append(Line(line: CTLineCreateWithAttributedString(NSAttributedString(string: " ")),
                                  baselineFromTop: Double(lines.count) * advance + ascent))
                continue
            }
            let ts = CTTypesetterCreateWithAttributedString(p)
            var start = 0
            while start < p.length {
                let n = CTTypesetterSuggestLineBreak(ts, start, width)
                guard n > 0 else { break }
                let line = CTTypesetterCreateLine(ts, CFRange(location: start, length: n))
                lines.append(Line(line: line, baselineFromTop: Double(lines.count) * advance + ascent))
                start += n
            }
        }
        let blockHeight = lines.isEmpty ? 0 : Double(lines.count - 1) * advance + ascent + descent + leading + bottomInset
        return Layout(lines: lines, blockHeight: blockHeight, style: style)
    }

    // MARK: Drawing

    static func makeContext() -> CGContext { GraphicRenderer.makeContext(width: width, height: height) }

    /// Theme layers only (background image / bars), full frame.
    public static func renderLayers(_ theme: LoadedNotesTheme) -> CGImage? {
        let ctx = makeContext()
        drawLayers(theme, in: ctx)
        return ctx.makeImage()
    }

    /// Slide text only, full frame, transparent elsewhere.
    public static func renderText(_ slide: NoteSlide, theme: NotesTheme) -> CGImage? {
        let ctx = makeContext()
        drawText(slide, theme: theme, in: ctx)
        return ctx.makeImage()
    }

    /// Layers + text: what the output shows with this slide live.
    public static func renderComposite(_ slide: NoteSlide?, theme: LoadedNotesTheme) -> CGImage? {
        let ctx = makeContext()
        drawLayers(theme, in: ctx)
        if let slide { drawText(slide, theme: theme.theme, in: ctx) }
        return ctx.makeImage()
    }

    /// The region worth showing in a thumbnail: all style boxes plus their layers, full width.
    public static func thumbnailCrop(_ theme: NotesTheme) -> CGRect {
        var r = CGRect.null
        for s in theme.styles.values { r = r.union(s.cgRect) }
        for l in theme.layers where l.type == "rect" {
            r = r.union(CGRect(x: l.rect[0], y: l.rect[1], width: l.rect[2], height: l.rect[3]))
        }
        let pad = 40.0
        let y0 = max(0, r.minY - pad), y1 = min(Double(height), r.maxY + pad)
        return CGRect(x: 0, y: y0, width: Double(width), height: y1 - y0)
    }

    /// A cropped, scaled thumbnail over a dark backdrop (for the control GUI). Rect in canvas coords (y down).
    public static func thumbnail(_ slide: NoteSlide, theme: LoadedNotesTheme, scale: Double = 0.5) -> CGImage? {
        guard let full = renderComposite(slide, theme: theme) else { return nil }
        let crop = thumbnailCrop(theme.theme)
        guard let cut = full.cropping(to: crop.integral) else { return nil }
        let w = Int(crop.width * scale), h = Int(crop.height * scale)
        let ctx = GraphicRenderer.makeContext(width: w, height: h)
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func drawLayers(_ theme: LoadedNotesTheme, in ctx: CGContext) {
        for l in theme.theme.layers {
            let r = cgRect(l.rect)
            switch l.type {
            case "image":
                if let src = l.src, let img = theme.images[src] {
                    ctx.saveGState(); ctx.setAlpha(l.opacity ?? 1); ctx.draw(img, in: r); ctx.restoreGState()
                }
            case "rect":
                ctx.setFillColor(CSSColor.parse(l.color ?? "#000000", opacity: l.opacity ?? 1))
                ctx.fill(r)
            default: break
            }
        }
    }

    static func drawText(_ slide: NoteSlide, theme: NotesTheme, in ctx: CGContext) {
        let lay = layout(slide, theme: theme)
        guard !lay.lines.isEmpty else { return }
        let outline = (theme.text.strokePercent ?? 0) != 0 ? layout(slide, theme: theme, strokePass: true) : nil
        let style = lay.style
        let top = lay.top
        ctx.saveGState()
        ctx.setAllowsFontSmoothing(true); ctx.setShouldSmoothFonts(true)
        if let sh = theme.text.shadow {
            let rad = sh.angle * .pi / 180
            // ProPresenter: 270° = straight down. CG y is up, so "down" is negative y.
            ctx.setShadow(offset: CGSize(width: cos(rad) * sh.offset, height: sin(rad) * sh.offset),
                          blur: sh.blur, color: CSSColor.parse(sh.color))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for l in (outline?.lines ?? []) + lay.lines {
            let lineWidth = Double(CTLineGetTypographicBounds(l.line, nil, nil, nil))
            let inner = Double(style.cgRect.width) - sidePadding * 2
            var x = Double(style.cgRect.minX) + sidePadding
            if style.align == "center" { x += (inner - lineWidth) / 2 }
            else if style.align == "right" { x += inner - lineWidth }
            let baselineY = Double(height) - (top + l.baselineFromTop)
            ctx.textPosition = CGPoint(x: x, y: baselineY)
            CTLineDraw(l.line, ctx)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Canvas rect (y down) → CG rect (y up).
    static func cgRect(_ r: [Double]) -> CGRect {
        CGRect(x: r[0], y: Double(height) - r[1] - r[3], width: r[2], height: r[3])
    }
}

// MARK: - Cue screen

/// The speaker's cue (confidence) screen: plain text, current on top, next below. Opaque black.
public enum CueRenderer {
    public struct Content: Equatable {
        public var current: NoteSlide?
        public var next: NoteSlide?
        public var footer: String
        public init(current: NoteSlide?, next: NoteSlide?, footer: String) {
            self.current = current; self.next = next; self.footer = footer
        }
    }

    public static func render(_ c: Content) -> CGImage? {
        let W = Double(NotesRenderer.width), H = Double(NotesRenderer.height)
        let ctx = NotesRenderer.makeContext()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let margin = 70.0
        let half = (H - 70) / 2
        // Divider
        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
        ctx.fill(CGRect(x: margin, y: H - half - 2, width: W - margin * 2, height: 3))

        label("NOW", y: 30, color: CGColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1), in: ctx)
        label("NEXT", y: half + 22, color: CGColor(srgbRed: 0.35, green: 0.8, blue: 0.45, alpha: 1), in: ctx)
        if let s = c.current {
            block(s, rect: CGRect(x: margin, y: 80, width: W - margin * 2, height: half - 100), maxSize: 70,
                  color: CGColor(gray: 1, alpha: 1), in: ctx)
        }
        if let s = c.next {
            block(s, rect: CGRect(x: margin, y: half + 72, width: W - margin * 2, height: half - 110), maxSize: 62,
                  color: CGColor(gray: 0.78, alpha: 1), in: ctx)
        }
        if !c.footer.isEmpty {
            let f = CTFontCreateWithName("HelveticaNeue" as CFString, 26, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: c.footer, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.5, alpha: 1),
            ]))
            ctx.textPosition = CGPoint(x: margin, y: 24)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    private static func label(_ s: String, y: Double, color: CGColor, in ctx: CGContext) {
        let f = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 30, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): 3.0,
        ]))
        ctx.textPosition = CGPoint(x: 70, y: Double(NotesRenderer.height) - y - 30)
        CTLineDraw(line, ctx)
    }

    /// Wrap `slide`'s text into `rect` (canvas coords, y down), shrinking until it fits.
    private static func block(_ slide: NoteSlide, rect: CGRect, maxSize: Double, color: CGColor, in ctx: CGContext) {
        var size = maxSize
        while size >= 24 {
            let reg = CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
            let bold = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
            let s = NSMutableAttributedString()
            for r in slide.runs {
                s.append(NSAttributedString(string: r.t, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): r.isBold ? bold : reg,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ]))
            }
            let fs = CTFramesetterCreateWithAttributedString(s)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: s.length), nil,
                                                                   CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            if fit.height <= rect.height || size <= 24 {
                let cgTop = Double(NotesRenderer.height) - rect.minY
                let path = CGPath(rect: CGRect(x: rect.minX, y: cgTop - fit.height - 2, width: rect.width, height: fit.height + 2), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: s.length), path, nil), ctx)
                return
            }
            size -= 4
        }
    }
}
