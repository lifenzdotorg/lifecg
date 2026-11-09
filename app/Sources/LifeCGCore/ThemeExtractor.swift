import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Vision

/// The result of building a theme from a sample PNG of one finished speaker title.
public struct ThemeExtraction {
    public var theme: Theme
    /// Full-frame layer under the bars (soft gradients etc.), with the bars and their shadows filled in.
    public var background: CGImage?
    /// Full-frame layer over the bars (crisp ornaments), including the parts that overlap the bars.
    public var foreground: CGImage?
    /// Detected rects, TOP-LEFT pixel coordinates, for the UI overlay.
    public var titleBar: CGRect
    public var designationBar: CGRect?
    public var titleInk: CGRect
    public var designationInk: CGRect?
    /// Plain-English notes for the operator.
    public var warnings: [String]
    /// 0…1: share of pixels around the graphic where a re-render of the sample texts matches the
    /// sample within 24/255 on every channel (only when the sample texts are known).
    public var matchScore: Double?
    /// Text each bar was calibrated against: typed by the operator, or read from the sample (OCR).
    public var titleTextUsed: String?
    public var designationTextUsed: String?
    /// 0…1: how closely the chosen font, at the fitted size and tracking, reproduces the sample's text.
    public var titleFontFit: Double?
    public var designationFontFit: Double?
}

public enum ThemeExtractorError: Error, LocalizedError {
    case unreadableImage
    case noBarFound

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "The image couldn't be read."
        case .noBarFound:
            return "No title bar found. The sample should show one finished speaker title: a solid (or mostly solid) "
                + "rectangle with the name written on it, ideally on a transparent background."
        }
    }
}

/// Builds a reusable `Theme` (plus background/foreground layers) from a sample PNG of one speaker title.
///
/// Outline:
/// 1. Bars: dominant-colour masks → connected components that are wide, mostly-filled rectangles with
///    something (text) inside. Stacked bars of the same colour are split where the row extents jump.
/// 2. Background estimate B: pixels away from the bars and not part of a crisp ornament are taken as
///    they are; the bars (plus a shadow margin) and ornaments are filled by harmonic interpolation.
/// 3. Bar colour: each bar pixel is "un-composited" from B (inverse of source-over), median taken.
///    Edges are refined to sub-pixel from the anti-aliased boundary pixels.
/// 4. Text: pixels inside a bar that differ from (bar over B). Components touching the bar's border are
///    ornaments, the rest is text. Text colour = the strongest text pixels; a coverage map follows.
/// 5. Size: with the sample text (typed, or read by OCR) the chosen font is rendered and the cap height
///    and tracking are fitted so the coverage's spread (2nd moments) matches; the centroid gives the
///    baseline and horizontal ink position, so padding comes out in the renderer's own terms. Without
///    text, a row-density profile gives baseline and cap height.
/// 6. Shadow: CoreGraphics shadows are rendered for a grid of offset/blur values and the opacity is
///    solved by least squares against the alpha excess around the bars.
/// 7. Layers: background = B; foreground = crisp pixels un-composited from what lies under them.
public enum ThemeExtractor {
    static let W = GraphicRenderer.width, H = GraphicRenderer.height
    /// Room around each bar that may hold its shadow; excluded from the background layer.
    static let shadowZone = 44

    public static func extract(sample: CGImage, id: String, name: String,
                               titleText: String?, designationText: String?,
                               titleFonts: [String], designationFonts: [String]) throws -> ThemeExtraction {
        try extract(sample: sample, id: id, name: name, titleText: titleText, designationText: designationText,
                    titleFonts: titleFonts, designationFonts: designationFonts, useOCR: true)
    }

    /// - Parameter useOCR: when a sample text isn't given, try to read it from the image (Vision).
    public static func extract(sample: CGImage, id: String, name: String,
                               titleText: String?, designationText: String?,
                               titleFonts: [String], designationFonts: [String], useOCR: Bool) throws -> ThemeExtraction {
        var warnings: [String] = []
        if sample.width != W || sample.height != H {
            warnings.append("The sample is \(sample.width)×\(sample.height); it was scaled to 1920×1080. Use a full-frame 1920×1080 PNG for exact sizes.")
        }
        let orig = PBuf.load(sample, w: W, h: H)
        guard orig.maxAlpha() > 0.02 else { throw ThemeExtractorError.noBarFound }

        // Opaque sample: key out the background colour.
        var img = orig
        let opaque = orig.opaqueFraction() > 0.995
        if opaque {
            let key = orig.cornerColor()
            img = orig.keyed(key)
            warnings.append("The sample has no transparency, so its background colour \(hexString(r: Double(key.0), g: Double(key.1), b: Double(key.2), a: 1)) was keyed out. "
                + "Bar alpha can't be measured and anything close to that colour may be lost. Export the sample with a transparent background for best results.")
        }

        // 1. Bars.
        var found = detectBars(img)
        if found.isEmpty && opaque { found = detectBars(orig, excludeBorderTouching: true) }
        guard !found.isEmpty else { throw ThemeExtractorError.noBarFound }
        if found.count > 2 {
            warnings.append("Found \(found.count) bar-like rectangles; using the two largest.")
            found = Array(found.sorted { $0.count > $1.count }.prefix(2))
        }
        found.sort { $0.rect.y0 < $1.rect.y0 }
        let irects = found.map(\.rect)

        // 2. Crisp ornaments (pass 1) and the background estimate.
        var inRect = [Bool](repeating: false, count: W * H)
        for r in irects { r.forEach(W, H) { inRect[$0] = true } }
        var near = [Bool](repeating: false, count: W * H)        // rect + 2 px ring
        for r in irects { r.expanded(2).forEach(W, H) { near[$0] = true } }
        var zone = [Bool](repeating: false, count: W * H)
        for r in irects { r.expanded(shadowZone).forEach(W, H) { zone[$0] = true } }
        var crisp = crispMask(img, exclude: near, bars: irects)
        var invalid = zone
        for i in 0..<(W * H) where crisp[i] { invalid[i] = true }
        let B = fillBackground(img, invalid: invalid)

        // 3–4. Per-bar colour, edges, text. An opaque sample is analysed as it is (against its own
        // interpolated background), not keyed, so colours stay true.
        let aImg = opaque ? orig : img
        let aB = opaque ? fillBackground(orig, invalid: invalid) : B
        var bars = found.map { analyzeBar($0, img: aImg, orig: opaque ? orig : nil, B: aB) }
        // Pass 2: ornament pixels in the ring right next to a bar (off the bar/background mix line).
        for bar in bars {
            bar.irect.expanded(2).forEach(W, H) { i in
                guard !inRect[i], !crisp[i] else { return }
                let u = over(bar.color, aB.px(i))
                if segmentResidual(aImg.px(i), aB.px(i), u).res > 0.2 { crisp[i] = true }
            }
        }
        if opaque && bars.count == 1 {
            warnings.append("Only one bar was found. A bar close to the sample's background colour can't be told apart from it.")
        }

        // 5. Sizes. Decide which bar is the title (larger text), then calibrate.
        if bars.count == 2 {
            let s0 = bars[0].inkSpreadY, s1 = bars[1].inkSpreadY
            if s1 > s0 * 1.03 { bars.swapAt(0, 1) }
        }
        let tFonts = titleFonts.isEmpty ? Theme.life.title.fonts : titleFonts
        let dFonts = designationFonts.isEmpty ? (Theme.life.designation?.fonts ?? tFonts) : designationFonts
        let tt = titleText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let dt = designationText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var fits: [TextFit] = []
        var barFonts: [[String]] = []
        var usedOCR = false, usedProfile = false
        for (k, bar) in bars.enumerated() {
            var fonts = k == 0 ? tFonts : dFonts
            var candidates: [(String, [String])] = []
            if bars.count == 1 {
                candidates = [tt.map { ($0, tFonts) }, dt.map { ($0, dFonts) }].compactMap { $0 }
                if tt != nil, dt != nil { warnings.append("Only one bar was found; it was matched against whichever sample text fits it best.") }
            } else if let t = k == 0 ? tt : dt { candidates = [(t, fonts)] }
            var fit: TextFit?
            if bar.textPixels > 0 {
                let tried = candidates.compactMap { c in calibrate(bar, text: c.0, fonts: c.1).map { ($0, c.1) } }
                if let best = tried.max(by: { $0.0.fit < $1.0.fit }) { fit = best.0; fonts = best.1 }
                if fit == nil, useOCR, let read = ocr(bar) {
                    if let f = calibrate(bar, text: read, fonts: fonts, fromOCR: true), f.fit > 0.6 { fit = f; usedOCR = true }
                }
            }
            if let f = fit, f.fit < 0.6, !f.fromOCR {
                warnings.append("The \(k == 0 ? "name" : "designation") text doesn't line up well with “\(f.text)” in \(fontLabel(fonts)) (fit \(Int(f.fit * 100))%). Check the text and font.")
            }
            if fit == nil {
                fit = profileFit(bar, fonts: fonts)
                usedProfile = true
            }
            fits.append(fit!)
            barFonts.append(fonts)
        }
        if bars[0].textPixels == 0 { warnings.append("No text was found on the name bar.") }
        if usedOCR { warnings.append("Sample text was read from the image (\(fits.filter(\.fromOCR).map { "“\($0.text)”" }.joined(separator: ", "))). Type the sample's name and designation to confirm the sizing.") }
        if usedProfile { warnings.append("Text size, baseline and letter spacing were estimated without the sample text. Type the sample's name and designation for an exact fit.") }
        if bars.count == 1, designationText?.isEmpty == false {
            warnings.append("No designation bar was found, so the theme has a name bar only.")
        }

        // Anchor.
        let anchor: Theme.Anchor
        if bars.count == 2 {
            let dl = abs(bars[0].rect.x0 - bars[1].rect.x0), dr = abs(bars[0].rect.x1 - bars[1].rect.x1)
            if abs(dl - dr) > 4 { anchor = dr < dl ? .right : .left }
            else { anchor = (bars[0].rect.x0 + bars[0].rect.x1) / 2 > Double(W) / 2 ? .right : .left }
        } else {
            anchor = (bars[0].rect.x0 + bars[0].rect.x1) / 2 > Double(W) / 2 ? .right : .left
        }

        // 6. Shadow.
        let shadow = fitShadow(bars, img: img, B: B, crisp: crisp, inRect: inRect)
        // The renderer draws a bar's shadow under the bar too, which shows through a semi-transparent bar.
        // If the sample looks like that (CoreGraphics-style), take the bar colour from under its shadow.
        if let shadow, !opaque {
            for k in bars.indices { correctForShadowUnder(bars, k, shadow: shadow, img: img, B: B) }
        }

        // 7. Layers.
        let bgLayer: PBuf? = B.maxAlpha() > 0.01 ? B : nil
        let fg = PBuf(w: W, h: H)
        for i in 0..<(W * H) where crisp[i] && !inRect[i] { fg.set(i, invOver(img.px(i), B.px(i))) }
        for bar in bars {
            for i in bar.ornamentPixels { fg.set(i, invOver(aImg.px(i), over(bar.color, aB.px(i)))) }
        }
        let fgLayer: PBuf? = fg.maxAlpha() > 0.01 ? fg : nil

        // Ornaments overlapping a bar's free end stay put while the bar resizes.
        for (k, bar) in bars.enumerated() where !bar.ornamentPixels.isEmpty {
            let freeX = anchor == .right ? bar.rect.x0 : bar.rect.x1
            if bar.ornamentPixels.contains(where: { abs(Double($0 % W) - freeX) < 6 }) {
                warnings.append("An ornament overlaps the free end of the \(k == 0 ? "name" : "designation") bar. It stays where it is when the bar resizes for other names.")
            }
        }
        for (k, bar) in bars.enumerated() where bar.colorSpread > 0.06 {
            warnings.append("The \(k == 0 ? "name" : "designation") bar isn't a flat colour (gradient or texture?). It will be drawn flat in the average colour.")
        }

        // Theme.
        func makeBar(_ bar: BarInfo, _ fit: TextFit, fonts: [String]) -> Theme.Bar {
            let r = bar.rect
            let anchorX = anchor == .right ? r.x1 : r.x0
            let padOuter = anchor == .right ? anchorX - fit.inkMaxX : fit.inkMinX - anchorX
            let padInner = r.width - padOuter - (fit.inkMaxX - fit.inkMinX)
            return Theme.Bar(anchorX: round2(anchorX), top: round2(r.y0), bottom: round2(r.y1),
                             padOuter: round2(padOuter), padInner: round2(padInner), baseline: round2(fit.baseline),
                             color: hex(bar.color, premultiplied: false), textColor: hex(bar.textColor, premultiplied: false),
                             fonts: fonts, capHeight: round2(fit.cap), tracking: (fit.tracking * 10000).rounded() / 10000,
                             uppercase: fit.uppercase, shadow: shadow)
        }
        var theme = Theme(id: id, name: name, anchor: anchor,
                          backgroundLayer: bgLayer == nil ? nil : "background.png",
                          foregroundLayer: fgLayer == nil ? nil : "foreground.png",
                          title: makeBar(bars[0], fits[0], fonts: barFonts[0]),
                          designation: bars.count > 1 ? makeBar(bars[1], fits[1], fonts: barFonts[1]) : nil,
                          notes: "Imported from a sample image")
        // Keep long names on screen: never closer than 40 px (or the sample's own margin) to the far edge.
        theme.edgeMargin = 40

        let bgImage = bgLayer?.makeImage(), fgImage = fgLayer?.makeImage()
        var result = ThemeExtraction(theme: theme, background: bgImage, foreground: fgImage,
                                     titleBar: bars[0].rect.cg, designationBar: bars.count > 1 ? bars[1].rect.cg : nil,
                                     titleInk: fits[0].inkRect, designationInk: bars.count > 1 ? fits[1].inkRect : nil,
                                     warnings: warnings, matchScore: nil,
                                     titleTextUsed: fits[0].text.nilIfEmpty, designationTextUsed: bars.count > 1 ? fits[1].text.nilIfEmpty : nil,
                                     titleFontFit: fits[0].text.isEmpty ? nil : fits[0].fit,
                                     designationFontFit: bars.count > 1 && !fits[1].text.isEmpty ? fits[1].fit : nil)

        // Re-render the sample texts and compare.
        if !fits[0].text.isEmpty {
            let rerender = renderComposite(theme: theme, background: bgImage, foreground: fgImage,
                                           title: fits[0].typed, designation: bars.count > 1 ? fits[1].typed : "")
            let cmp = compare(img, rerender, region: comparisonRegion(irects, fg: fgLayer))
            result.matchScore = 1 - cmp.mismatch
            if cmp.mismatch > 0.05 {
                result.warnings.append("A re-render differs noticeably from the sample (\(String(format: "%.1f", cmp.mismatch * 100))% of pixels). Check the preview.")
            }
        }
        return result
    }

    /// The sample texts drawn with an extracted theme and layers (premultiplied RGBA image).
    public static func renderPreview(_ e: ThemeExtraction, title: String, designation: String) -> CGImage? {
        renderComposite(theme: e.theme, background: e.background, foreground: e.foreground,
                        title: title, designation: designation).makeImage()
    }

    /// Fraction of pixels (in the area around the graphic) whose channels differ by more than `threshold`/255.
    /// - Parameter region: top-left pixel rect to compare (default: around everything fairly opaque in either image).
    public static func mismatch(_ a: CGImage, _ b: CGImage, threshold: Int = 24, region: CGRect? = nil) -> (fraction: Double, meanAbs: Double) {
        let pa = PBuf.load(a, w: W, h: H), pb = PBuf.load(b, w: W, h: H)
        if let region {
            let r = IRect(x0: Int(region.minX), y0: Int(region.minY), x1: Int(region.maxX), y1: Int(region.maxY)).clipped(W, H)
            let c = compare(pa, pb, region: r, threshold: Float(threshold) / 255)
            return (c.mismatch, c.meanAbs)
        }
        // Region: bbox of everything opaque-ish in either image.
        var x0 = W, y0 = H, x1 = 0, y1 = 0
        for y in 0..<H { for x in 0..<W {
            let i = y * W + x
            if pa.p[i * 4 + 3] > 0.35 || pb.p[i * 4 + 3] > 0.35 { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1) }
        } }
        guard x1 > x0 else { return (0, 0) }
        let r = IRect(x0: x0, y0: y0, x1: x1, y1: y1).expanded(20).clipped(W, H)
        let c = compare(pa, pb, region: r, threshold: Float(threshold) / 255)
        return (c.mismatch, c.meanAbs)
    }

    // MARK: - Bars

    struct Found { var rect: IRect; var seed: RGBA; var count: Int }

    static func detectBars(_ img: PBuf, excludeBorderTouching: Bool = false) -> [Found] {
        let n = W * H
        var counts = [Int](repeating: 0, count: 65536)
        var sums = [Float](repeating: 0, count: 65536 * 4)
        img.p.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let a = p[i * 4 + 3]
                guard a >= 0.45 else { continue }
                let r = p[i * 4] / a, g = p[i * 4 + 1] / a, b = p[i * 4 + 2] / a
                let key = (q16(r) << 12) | (q16(g) << 8) | (q16(b) << 4) | q16(a)
                counts[key] += 1
                sums[key * 4] += r; sums[key * 4 + 1] += g; sums[key * 4 + 2] += b; sums[key * 4 + 3] += a
            }
        }
        let bins = (0..<65536).filter { counts[$0] >= 600 }.sorted { counts[$0] > counts[$1] }.prefix(12)
        var accepted: [Found] = []
        var claimed = [Bool](repeating: false, count: n)
        let unp = img.unpremultiplied()
        for bin in bins {
            let c = Float(counts[bin])
            let seed = RGBA(sums[bin * 4] / c, sums[bin * 4 + 1] / c, sums[bin * 4 + 2] / c, sums[bin * 4 + 3] / c)
            var mask = [Bool](repeating: false, count: n)
            unp.withUnsafeBufferPointer { u in
                for i in 0..<n {
                    let a = u[i * 4 + 3]
                    guard a >= 0.4 else { continue }
                    if abs(u[i * 4] - seed.r) <= 0.085 && abs(u[i * 4 + 1] - seed.g) <= 0.085
                        && abs(u[i * 4 + 2] - seed.b) <= 0.085 && abs(a - seed.a) <= 0.085 { mask[i] = true }
                }
            }
            for comp in components(mask, W, H, eight: false, minCount: 1200) {
                if excludeBorderTouching && (comp.x0 == 0 || comp.y0 == 0 || comp.x1 == W || comp.y1 == H) { continue }
                let cl = comp.pixels.reduce(0) { $0 + (claimed[Int($1)] ? 1 : 0) }
                if Double(cl) > 0.5 * Double(comp.count) { continue }
                for r in rects(from: comp) {
                    accepted.append(Found(rect: r, seed: seed, count: r.area))
                    r.forEach(W, H) { claimed[$0] = true }
                }
            }
        }
        return accepted
    }

    private static func q16(_ v: Float) -> Int { min(15, max(0, Int(v * 16))) }

    /// Bar rectangles in one component: split stacked bars, find edges from the outside in, validate.
    static func rects(from comp: Comp) -> [IRect] {
        let bw = comp.x1 - comp.x0, bh = comp.y1 - comp.y0
        guard bw >= 60, bh >= 12 else { return [] }
        var grid = [Bool](repeating: false, count: bw * bh)
        for p in comp.pixels { let x = Int(p) % W - comp.x0, y = Int(p) / W - comp.y0; grid[y * bw + x] = true }
        var rowCount = [Int](repeating: 0, count: bh), rowMin = [Int](repeating: bw, count: bh), rowMax = [Int](repeating: -1, count: bh)
        for y in 0..<bh { for x in 0..<bw where grid[y * bw + x] {
            rowCount[y] += 1; rowMin[y] = min(rowMin[y], x); rowMax[y] = max(rowMax[y], x)
        } }
        let maxRow = rowCount.max() ?? 0
        guard let top = rowCount.firstIndex(where: { Double($0) >= 0.3 * Double(maxRow) }),
              let bottom = rowCount.lastIndex(where: { Double($0) >= 0.3 * Double(maxRow) }) else { return [] }

        // Split where the row extents jump and stay (two stacked bars of the same colour).
        var segments = [(top, bottom + 1)]
        let rows = Array(top...bottom)
        if rows.count >= 26 {
            func cost(_ a: Int, _ b: Int, _ v: [Int]) -> (Double, Double) {   // SSE and mean over rows[a..<b]
                let s = rows[a..<b].map { Double(v[$0]) }
                let m = s.reduce(0, +) / Double(s.count)
                return (s.reduce(0) { $0 + ($1 - m) * ($1 - m) }, m)
            }
            let whole = cost(0, rows.count, rowMin).0 + cost(0, rows.count, rowMax).0
            var best: (Double, Int) = (.infinity, -1)
            for s in 12...(rows.count - 12) {
                let c = cost(0, s, rowMin).0 + cost(s, rows.count, rowMin).0 + cost(0, s, rowMax).0 + cost(s, rows.count, rowMax).0
                if c < best.0 { best = (c, s) }
            }
            if best.1 > 0 {
                let s = best.1
                let jumpL = abs(cost(0, s, rowMin).1 - cost(s, rows.count, rowMin).1)
                let jumpR = abs(cost(0, s, rowMax).1 - cost(s, rows.count, rowMax).1)
                let rms = sqrt(best.0 / Double(rows.count * 2))
                if max(jumpL, jumpR) >= 6 && best.0 < 0.15 * whole && rms < 3 {
                    segments = [(top, top + s), (top + s, bottom + 1)]
                }
            }
        }

        var out: [IRect] = []
        for (ya, yb) in segments {
            let nrows = yb - ya
            var colCount = [Int](repeating: 0, count: bw)
            for y in ya..<yb { for x in 0..<bw where grid[y * bw + x] { colCount[x] += 1 } }
            guard let x0 = colCount.firstIndex(where: { Double($0) >= 0.25 * Double(nrows) }),
                  let x1 = colCount.lastIndex(where: { Double($0) >= 0.25 * Double(nrows) }) else { continue }
            var rc = [Int](repeating: 0, count: bh)
            for y in 0..<bh { for x in x0...x1 where grid[y * bw + x] { rc[y] += 1 } }
            let w = x1 - x0 + 1
            let segRows = Array(ya..<yb)
            guard let y0 = segRows.first(where: { Double(rc[$0]) >= 0.3 * Double(w) }),
                  let y1 = segRows.last(where: { Double(rc[$0]) >= 0.3 * Double(w) }) else { continue }
            let r = IRect(x0: comp.x0 + x0, y0: comp.y0 + y0, x1: comp.x0 + x1 + 1, y1: comp.y0 + y1 + 1)
            var filled = 0
            for y in y0...y1 { for x in x0...x1 where grid[y * bw + x] { filled += 1 } }
            let fill = Double(filled) / Double(r.area)
            // A text bar: wide, mostly filled, and with something (text) inside it.
            guard r.width >= 60, r.height >= 12, Double(r.width) >= 1.5 * Double(r.height),
                  fill >= 0.45, fill <= 0.995 else { continue }
            out.append(r)
        }
        return out
    }

    // MARK: - Crisp ornaments

    /// Pixels belonging to crisp (sharp-edged) decoration outside the bars: edges where neighbouring pixels
    /// differ sharply, plus the insides of fairly opaque shapes whose outline is sharp.
    static func crispMask(_ img: PBuf, exclude: [Bool], bars: [IRect]) -> [Bool] {
        let n = W * H
        var edge = [Bool](repeating: false, count: n)
        img.p.withUnsafeBufferPointer { p in
            for y in 0..<H { for x in 0..<W {
                let i = y * W + x
                if exclude[i] { continue }
                var m: Float = 0
                for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < W, yy < H else { continue }
                    let j = yy * W + xx
                    for c in 0..<4 { m = max(m, abs(p[i * 4 + c] - p[j * 4 + c])) }
                }
                if m > 0.08 { edge[i] = true }
            }
        }
        }
        var crisp = dilate(edge, 1)
        for i in 0..<n where exclude[i] { crisp[i] = false }
        // Fairly opaque shapes with sharp outlines.
        // Edges split a shape's inside from a soft surrounding of similar alpha (e.g. a dark corner gradient).
        var solid = [Bool](repeating: false, count: n)
        for i in 0..<n where !exclude[i] && !edge[i] && img.p[i * 4 + 3] >= 0.3 { solid[i] = true }
        for comp in components(solid, W, H, eight: false, minCount: 4) {
            if bars.contains(where: { b in comp.x0 <= (b.x0 + b.x1) / 2 && comp.x1 > (b.x0 + b.x1) / 2
                && comp.y0 <= (b.y0 + b.y1) / 2 && comp.y1 > (b.y0 + b.y1) / 2 }) { continue }
            var boundary = 0, sharp = 0
            for p in comp.pixels {
                let i = Int(p), x = i % W, y = i / W
                var isB = false, isSharp = false
                for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < W, yy < H else { continue }
                    let j = yy * W + xx
                    if !solid[j] && !exclude[j] { isB = true; if edge[j] { isSharp = true } }
                }
                if isB { boundary += 1; if isSharp { sharp += 1 } }
            }
            if boundary == 0 || Double(sharp) >= 0.5 * Double(boundary) {
                for p in comp.pixels { crisp[Int(p)] = true }
            }
        }
        return crisp
    }

    // MARK: - Background fill

    /// Copy of `img` with `invalid` pixels replaced by a smooth interpolation of the valid ones: for each
    /// large hole a quadratic surface is fitted to a band of valid pixels around it (this follows a gradient's
    /// trend, even towards a frame edge with no data), and the residual is filled harmonically.
    static func fillBackground(_ img: PBuf, invalid: [Bool]) -> PBuf {
        let out = img.copy()
        let holes = components(invalid, W, H, eight: false, minCount: 1)
        guard !holes.isEmpty else { return out }
        // Base surface P (premultiplied, per channel); the residual img − P is what gets interpolated.
        var base = [Float](repeating: 0, count: W * H * 4)
        let band = 60
        for hole in holes where hole.count >= 2000 {
            let box = IRect(x0: hole.x0, y0: hole.y0, x1: hole.x1, y1: hole.y1).expanded(band).clipped(W, H)
            let cx = Double(hole.x0 + hole.x1) / 2, cy = Double(hole.y0 + hole.y1) / 2
            let sx = max(Double(hole.x1 - hole.x0) / 2 + Double(band), 1), sy = max(Double(hole.y1 - hole.y0) / 2 + Double(band), 1)
            func terms(_ x: Int, _ y: Int) -> [Double] {
                let u = (Double(x) - cx) / sx, v = (Double(y) - cy) / sy
                return [1, u, v, u * u, u * v, v * v]
            }
            // Normal equations over valid pixels within the box (every other pixel).
            var ata = [Double](repeating: 0, count: 36), atb = [Double](repeating: 0, count: 24)
            var n = 0
            for y in stride(from: box.y0, to: box.y1, by: 2) { for x in stride(from: box.x0, to: box.x1, by: 2) {
                let i = y * W + x
                if invalid[i] { continue }
                let t = terms(x, y)
                for a in 0..<6 { for b in 0..<6 { ata[a * 6 + b] += t[a] * t[b] }
                    for c in 0..<4 { atb[c * 6 + a] += t[a] * Double(img.p[i * 4 + c]) } }
                n += 1
            } }
            guard n > 50 else { continue }
            for a in 0..<6 { ata[a * 6 + a] += 1e-6 * Double(n) }   // tiny ridge for stability
            guard let coef = solve(ata, atb, 6, 4) else { continue }
            box.forEach(W, H) { i in
                let t = terms(i % W, i / W)
                for c in 0..<4 {
                    var v = 0.0
                    for a in 0..<6 { v += coef[c * 6 + a] * t[a] }
                    base[i * 4 + c] = Float(v)
                }
            }
        }
        // Residual, filled harmonically (successive over-relaxation; free boundary at the frame edge).
        var res = [Float](repeating: 0, count: W * H * 4)
        for i in 0..<(W * H) where !invalid[i] { for c in 0..<4 { res[i * 4 + c] = img.p[i * 4 + c] - base[i * 4 + c] } }
        var idx: [Int] = []
        idx.reserveCapacity(holes.reduce(0) { $0 + $1.count })
        for h in holes { for p in h.pixels { idx.append(Int(p)) } }
        let omega: Float = 1.9
        res.withUnsafeMutableBufferPointer { p in
            for _ in 0..<400 {
                for i in idx {
                    let x = i % W, y = i / W
                    var n: Float = 0
                    var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
                    if x > 0 { let j = (i - 1) * 4; s0 += p[j]; s1 += p[j + 1]; s2 += p[j + 2]; s3 += p[j + 3]; n += 1 }
                    if x < W - 1 { let j = (i + 1) * 4; s0 += p[j]; s1 += p[j + 1]; s2 += p[j + 2]; s3 += p[j + 3]; n += 1 }
                    if y > 0 { let j = (i - W) * 4; s0 += p[j]; s1 += p[j + 1]; s2 += p[j + 2]; s3 += p[j + 3]; n += 1 }
                    if y < H - 1 { let j = (i + W) * 4; s0 += p[j]; s1 += p[j + 1]; s2 += p[j + 2]; s3 += p[j + 3]; n += 1 }
                    let k = i * 4
                    p[k] += omega * (s0 / n - p[k]); p[k + 1] += omega * (s1 / n - p[k + 1])
                    p[k + 2] += omega * (s2 / n - p[k + 2]); p[k + 3] += omega * (s3 / n - p[k + 3])
                }
            }
        }
        for i in idx {   // keep it a valid premultiplied colour
            let k = i * 4
            let a = min(max(base[k + 3] + res[k + 3], 0), 1)
            out.p[k + 3] = a
            for c in 0..<3 { out.p[k + c] = min(max(base[k + c] + res[k + c], 0), a) }
        }
        return out
    }

    /// Solve (A x = b) for `m` right-hand sides; A is n×n row-major, b holds m vectors of n. Gaussian elimination.
    static func solve(_ A: [Double], _ b: [Double], _ n: Int, _ m: Int) -> [Double]? {
        var a = A, x = b
        for col in 0..<n {
            var piv = col
            for r in col..<n where abs(a[r * n + col]) > abs(a[piv * n + col]) { piv = r }
            guard abs(a[piv * n + col]) > 1e-12 else { return nil }
            if piv != col {
                for k in 0..<n { a.swapAt(col * n + k, piv * n + k) }
                for c in 0..<m { x.swapAt(c * n + col, c * n + piv) }
            }
            for r in 0..<n where r != col {
                let f = a[r * n + col] / a[col * n + col]
                if f == 0 { continue }
                for k in col..<n { a[r * n + k] -= f * a[col * n + k] }
                for c in 0..<m { x[c * n + r] -= f * x[c * n + col] }
            }
        }
        for c in 0..<m { for r in 0..<n { x[c * n + r] /= a[r * n + r] } }
        return x
    }

    // MARK: - Per-bar analysis

    final class BarInfo {
        var irect: IRect
        var rect = DRect(x0: 0, y0: 0, x1: 0, y1: 0)
        var color = RGBA(0, 0, 0, 0)          // premultiplied
        var seed = RGBA(0, 0, 0, 0)           // unpremultiplied detection colour
        var colorSpread: Float = 0
        var textColor = RGBA(0, 0, 0, 1)      // premultiplied
        /// Local (irect) maps.
        var cov: [Float] = []
        var textMask: [Bool] = []
        var textPixels = 0
        var ornamentPixels: [Int] = []        // global indices
        var inkSpreadY: Double = 0
        init(_ r: IRect) { irect = r }
        var lw: Int { irect.width }
        var lh: Int { irect.height }
    }

    static func analyzeBar(_ f: Found, img: PBuf, orig: PBuf?, B: PBuf) -> BarInfo {
        var f = f
        if orig != nil { f.seed = dominantColor(img, f.rect.expanded(-2)) ?? f.seed }   // detection ran on the keyed image
        let bar = BarInfo(f.rect)
        bar.seed = f.seed
        let r = f.rect
        // Colour: un-composite bar-coloured pixels from the background estimate.
        var rs: [Float] = [], gs: [Float] = [], bs: [Float] = [], as_: [Float] = []
        let inner = r.expanded(-2)
        inner.forEach(W, H) { i in
            let c = img.px(i)
            guard c.a > 0.05 else { return }
            let u = c.unpremul
            guard abs(u.r - f.seed.r) <= 0.1 && abs(u.g - f.seed.g) <= 0.1 && abs(u.b - f.seed.b) <= 0.1 && abs(u.a - f.seed.a) <= 0.1 else { return }
            if let orig {
                let o = orig.px(i).unpremul
                rs.append(o.r); gs.append(o.g); bs.append(o.b); as_.append(1)
            } else {
                let fpx = invOver(c, B.px(i))
                guard fpx.a > 0.05 else { return }
                let fu = fpx.unpremul
                rs.append(fu.r); gs.append(fu.g); bs.append(fu.b); as_.append(fpx.a)
            }
        }
        let mr = median(rs), mg = median(gs), mb = median(bs), ma = median(as_)
        bar.color = RGBA(mr * ma, mg * ma, mb * ma, ma)
        bar.colorSpread = max(mad(rs), mad(gs), mad(bs))

        // Sub-pixel edges.
        bar.rect = refineEdges(r, color: bar.color, img: img, B: B)

        // Text and ornaments inside the bar.
        let lw = r.width, lh = r.height
        var diff = [Bool](repeating: false, count: lw * lh)
        for y in 0..<lh { for x in 0..<lw {
            let i = (r.y0 + y) * W + r.x0 + x
            let c = img.px(i), b = B.px(i), u = over(bar.color, b)
            let border = x == 0 || y == 0 || x == lw - 1 || y == lh - 1
            if border && segmentResidual(c, b, u).res < 0.06 { continue }      // bar edge anti-aliased over the background
            if maxDiff(c, u) > 0.1 { diff[y * lw + x] = true }
        } }
        var textMask = [Bool](repeating: false, count: lw * lh)
        var ornLocal = [Bool](repeating: false, count: lw * lh)
        for comp in components(diff, lw, lh, eight: true, minCount: 3) {
            let touches = comp.x0 <= 0 || comp.y0 <= 0 || comp.x1 >= lw || comp.y1 >= lh
            for p in comp.pixels { if touches { ornLocal[Int(p)] = true } else { textMask[Int(p)] = true } }
        }
        let ornD = dilate(ornLocal, 1, w: lw, h: lh)
        for k in 0..<(lw * lh) where ornD[k] && !textMask[k] {
            let i = (r.y0 + k / lw) * W + r.x0 + k % lw
            let c = img.px(i), u = over(bar.color, B.px(i))
            if ornLocal[k] || maxDiff(c, u) > 0.03 { bar.ornamentPixels.append(i) }
        }
        bar.textMask = textMask
        bar.textPixels = textMask.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard bar.textPixels > 0 else { bar.cov = [Float](repeating: 0, count: lw * lh); return bar }

        // Text colour: the strongest text pixels.
        var cand: [(Float, Int)] = []
        for k in 0..<(lw * lh) where textMask[k] {
            let i = (r.y0 + k / lw) * W + r.x0 + k % lw
            cand.append((maxDiff(img.px(i), over(bar.color, B.px(i))), i))
        }
        cand.sort { $0.0 > $1.0 }
        let top = cand.prefix(max(3, cand.count * 6 / 100))
        let src = orig ?? img
        let tu = top.map { src.px($0.1).unpremul }
        let tr = median(tu.map(\.r)), tg = median(tu.map(\.g)), tb = median(tu.map(\.b))
        var ta: Float = 1
        let ua = median(top.map { over(bar.color, B.px($0.1)).a })
        if orig == nil && ua < 0.97 {
            ta = min(max((median(tu.map(\.a)) - ua) / (1 - ua), 0), 1)
            if ta > 0.95 { ta = 1 }
        }
        bar.textColor = RGBA(tr * ta, tg * ta, tb * ta, ta)

        // Coverage map of the text (0…1).
        let tmD = dilate(textMask, 1, w: lw, h: lh)
        var cov = [Float](repeating: 0, count: lw * lh)
        for k in 0..<(lw * lh) where tmD[k] && !ornLocal[k] {
            let i = (r.y0 + k / lw) * W + r.x0 + k % lw
            let c = src.px(i)
            let u = orig != nil ? bar.color : over(bar.color, B.px(i))
            let t = over(bar.textColor, u)
            let d = t - u
            let dd = d.dot(d)
            guard dd > 1e-4 else { continue }
            cov[k] = min(max((c - u).dot(d) / dd, 0), 1)
        }
        bar.cov = cov
        bar.inkSpreadY = Moments(cov, lw, lh).sy
        return bar
    }

    /// Mean unpremultiplied colour of the most common (quantised) colour in `r`.
    static func dominantColor(_ img: PBuf, _ r: IRect) -> RGBA? {
        var bins: [Int: (n: Int, s: RGBA)] = [:]
        r.forEach(W, H) { i in
            let c = img.px(i)
            guard c.a >= 0.3 else { return }
            let u = c.unpremul
            let key = (q16(u.r) << 12) | (q16(u.g) << 8) | (q16(u.b) << 4) | q16(u.a)
            let e = bins[key] ?? (0, RGBA(0, 0, 0, 0))
            bins[key] = (e.n + 1, e.s + u)
        }
        guard let best = bins.values.max(by: { $0.n < $1.n }) else { return nil }
        return best.s * (1 / Float(best.n))
    }

    /// Sub-pixel edges: scan outwards from inside the bar; the first non-bar pixel's position on the
    /// background→bar mix line gives the fractional coverage. Median over all scanlines.
    static func refineEdges(_ r: IRect, color: RGBA, img: PBuf, B: PBuf) -> DRect {
        func barlike(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < W, y < H else { return false }
            let i = y * W + x
            return maxDiff(img.px(i), over(color, B.px(i))) < 0.08
        }
        func frac(_ x: Int, _ y: Int) -> Double {
            let i = y * W + x
            let s = segmentResidual(img.px(i), B.px(i), over(color, B.px(i)))
            return s.res < 0.06 ? Double(s.t) : 0
        }
        func scan(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int) -> Double? {
            guard barlike(sx, sy) else { return nil }
            var x = sx, y = sy, steps = 0
            while barlike(x + dx, y + dy) && steps < 12 { x += dx; y += dy; steps += 1 }
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= W || ny >= H { return Double(dx != 0 ? (dx > 0 ? W : 0) : (dy > 0 ? H : 0)) }
            let t = frac(nx, ny)
            if dx > 0 { return Double(nx) + t }
            if dx < 0 { return Double(nx) + 1 - t }
            if dy > 0 { return Double(ny) + t }
            return Double(ny) + 1 - t
        }
        var L: [Double] = [], R: [Double] = [], T: [Double] = [], Bt: [Double] = []
        for y in (r.y0 + 3)..<max(r.y0 + 4, r.y1 - 3) {
            if let v = scan(r.x0 + 4, y, -1, 0) { L.append(v) }
            if let v = scan(r.x1 - 5, y, 1, 0) { R.append(v) }
        }
        for x in (r.x0 + 3)..<max(r.x0 + 4, r.x1 - 3) {
            if let v = scan(x, r.y0 + 4, 0, -1) { T.append(v) }
            if let v = scan(x, r.y1 - 5, 0, 1) { Bt.append(v) }
        }
        func med(_ a: [Double], _ fallback: Int) -> Double {
            guard !a.isEmpty else { return Double(fallback) }
            let s = a.sorted(); return s[s.count / 2]
        }
        return DRect(x0: med(L, r.x0), y0: med(T, r.y0), x1: med(R, r.x1), y1: med(Bt, r.y1))
    }

    // MARK: - Text calibration

    struct TextFit {
        var text: String           // as drawn (after uppercasing)
        var typed: String          // as given
        var cap: Double
        var tracking: Double
        var uppercase: Bool
        var baseline: Double       // global, top-down
        var inkMinX: Double        // global x of CTLineGetImageBounds
        var inkMaxX: Double
        var inkRect: CGRect        // global, top-left coords
        var fit: Double
        var fromOCR = false
    }

    struct Moments {
        var sum = 0.0, cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        init(_ cov: [Float], _ w: Int, _ h: Int, dx: Double = 0, dy: Double = 0) {
            var s = 0.0, sxv = 0.0, syv = 0.0, sxx = 0.0, syy = 0.0
            cov.withUnsafeBufferPointer { c in
                for y in 0..<h { for x in 0..<w {
                    let v = Double(c[y * w + x]); if v <= 0 { continue }
                    let fx = Double(x) + 0.5 + dx, fy = Double(y) + 0.5 + dy
                    s += v; sxv += v * fx; syv += v * fy; sxx += v * fx * fx; syy += v * fy * fy
                } }
            }
            guard s > 0 else { return }
            sum = s; cx = sxv / s; cy = syv / s
            sx = sqrt(max(sxx / s - cx * cx, 0)); sy = sqrt(max(syy / s - cy * cy, 0))
        }
    }

    /// Same sizing as `GraphicRenderer.makeLine` (cap height → point size, tracking in em), without shrink-to-fit.
    static func line(_ text: String, fonts: [String], cap: Double, tracking: Double) -> CTLine {
        let base = GraphicRenderer.resolveFont(fonts)
        let capRatio = max(CTFontGetCapHeight(base) / 100, 0.1)
        let f = CTFontCreateCopyWithAttributes(base, cap / capRatio, nil, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            NSAttributedString.Key(kCTKernAttributeName as String): tracking * CTFontGetSize(f),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// Text coverage on a w×h canvas (top-left coords) with the pen at (originX, baseline).
    static func coverage(_ line: CTLine, w: Int, h: Int, originX: Double, baseline: Double) -> [Float] {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.textPosition = CGPoint(x: originX, y: Double(h) - baseline)
        CTLineDraw(line, ctx)
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: w * h)
        for k in 0..<(w * h) { out[k] = Float(d[k * 4 + 3]) / 255 }
        return out
    }

    /// Moments of a line's coverage relative to its pen origin (x) and baseline (y, positive down).
    static func lineMoments(_ line: CTLine) -> Moments {
        let ib = CTLineGetImageBounds(line, nil)
        let w = max(Int(ceil(ib.width)) + 18, 8), h = max(Int(ceil(ib.height)) + 18, 8)
        // Whole-pixel pen position: CoreGraphics snaps glyphs to the pixel grid vertically.
        let ox = (8 - Double(ib.minX)).rounded(.up), oyCG = (8 - Double(ib.minY)).rounded(.up)
        let cov = coverage(line, w: w, h: h, originX: ox, baseline: Double(h) - oyCG)
        return Moments(cov, w, h, dx: -ox, dy: -(Double(h) - oyCG))
    }

    static func calibrate(_ bar: BarInfo, text typed: String, fonts: [String], fromOCR: Bool = false) -> TextFit? {
        var variants = [(typed, false)]
        if typed.uppercased() != typed { variants.append((typed.uppercased(), true)) }
        return variants.compactMap { calibrateOne(bar, text: $0.0, typed: typed, uppercase: $0.1, fonts: fonts, fromOCR: fromOCR) }
            .max { $0.fit < $1.fit }
    }

    static func calibrateOne(_ bar: BarInfo, text: String, typed: String, uppercase: Bool, fonts: [String], fromOCR: Bool) -> TextFit? {
        let lw = bar.lw, lh = bar.lh
        let s = Moments(bar.cov, lw, lh)
        guard s.sum > 0, s.sy > 0.5, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var cap = max(s.sy * 2.5, 4), tracking = 0.05
        func fitCap() {
            for _ in 0..<4 {
                let m = lineMoments(line(text, fonts: fonts, cap: cap, tracking: tracking))
                guard m.sy > 0 else { return }
                cap *= s.sy / m.sy
            }
        }
        func fitTracking(_ lo0: Double, _ hi0: Double) {
            var lo = lo0, hi = hi0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                let m = lineMoments(line(text, fonts: fonts, cap: cap, tracking: mid))
                if m.sx < s.sx { lo = mid } else { hi = mid }
            }
            tracking = (lo + hi) / 2
        }
        fitCap()
        fitTracking(-0.2, 0.8)
        fitCap()
        fitTracking(tracking - 0.05, tracking + 0.05)
        let ln = line(text, fonts: fonts, cap: cap, tracking: tracking)
        let m = lineMoments(ln)
        let originX = s.cx - m.cx, baseline = s.cy - m.cy
        let rendered = coverage(ln, w: lw, h: lh, originX: originX, baseline: baseline)
        var num: Float = 0, den: Float = 0
        for k in 0..<(lw * lh) { num += abs(rendered[k] - bar.cov[k]); den += rendered[k] + bar.cov[k] }
        let fit = den > 0 ? Double(1 - num / den) : 0
        let ib = CTLineGetImageBounds(ln, nil)
        let gx = Double(bar.irect.x0) + originX, gb = Double(bar.irect.y0) + baseline
        return TextFit(text: text, typed: typed, cap: cap, tracking: tracking, uppercase: uppercase, baseline: gb,
                       inkMinX: gx + ib.minX, inkMaxX: gx + ib.maxX,
                       inkRect: CGRect(x: gx + ib.minX, y: gb - ib.maxY, width: ib.width, height: ib.height),
                       fit: fit, fromOCR: fromOCR)
    }

    /// Estimate from the coverage profile alone (no sample text).
    static func profileFit(_ bar: BarInfo, fonts: [String]) -> TextFit {
        let lw = bar.lw, lh = bar.lh
        var colMax = [Float](repeating: 0, count: lw), rowSum = [Float](repeating: 0, count: lh)
        for y in 0..<lh { for x in 0..<lw { let v = bar.cov[y * lw + x]; colMax[x] = max(colMax[x], v); rowSum[y] += v } }
        let r = bar.rect
        guard let cx0 = colMax.firstIndex(where: { $0 > 0.04 }), let cx1 = colMax.lastIndex(where: { $0 > 0.04 }),
              let maxRow = rowSum.max(), maxRow > 0 else {
            // No text: centre a nominal line.
            let cap = r.height * 0.45
            return TextFit(text: "", typed: "", cap: cap, tracking: 0.04, uppercase: false, baseline: r.y1 - (r.height - cap) / 2,
                           inkMinX: r.x0 + r.height * 0.4, inkMaxX: r.x1 - r.height * 0.4,
                           inkRect: CGRect(x: r.x0, y: r.y0, width: r.width, height: r.height), fit: 0)
        }
        let minX = Double(cx0) + 1 - Double(colMax[cx0]), maxX = Double(cx1) + Double(colMax[cx1])
        let rowsThr = rowSum.map { $0 > 0.02 * maxRow }
        let top = rowsThr.firstIndex(of: true)!, bottom = rowsThr.lastIndex(of: true)!
        // Ink top with sub-pixel estimate from the first row's density relative to the next.
        let topF = Double(top) + 1 - Double(min(1, rowSum[top] / max(rowSum[min(top + 1, lh - 1)], 1e-3)))
        // Baseline: bottom of the dense band (descenders are sparse).
        let dense = (0..<lh).filter { rowSum[$0] >= 0.3 * maxRow }
        let last = dense.last ?? bottom
        let prev = rowSum[max(last - 1, 0)]
        let baseLocal = Double(last) + Double(min(1, rowSum[last] / max(prev, 1e-3)))
        // Ink top is the taller of cap height and ascenders; scale by the font's own ratio.
        let probe = line("H", fonts: fonts, cap: 100, tracking: 0), asc = line("Hdhklbf", fonts: fonts, cap: 100, tracking: 0)
        let ratio = Double(CTLineGetImageBounds(probe, nil).maxY / max(CTLineGetImageBounds(asc, nil).maxY, 1))
        let cap = (baseLocal - topF) * min(ratio, 1)
        let gx = Double(bar.irect.x0), gy = Double(bar.irect.y0)
        return TextFit(text: "", typed: "", cap: cap, tracking: 0.04, uppercase: false, baseline: gy + baseLocal,
                       inkMinX: gx + minX, inkMaxX: gx + maxX,
                       inkRect: CGRect(x: gx + minX, y: gy + topF, width: maxX - minX, height: Double(bottom + 1) - topF), fit: 0)
    }

    /// Read a bar's text with Vision (rendered as black on white from the coverage map).
    static func ocr(_ bar: BarInfo) -> String? {
        let lw = bar.lw, lh = bar.lh, pad = 24, scale = 2
        let w = (lw + 2 * pad) * scale, h = (lh + 2 * pad) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let lx = x / scale - pad, ly = y / scale - pad
            let v: Float = (lx >= 0 && ly >= 0 && lx < lw && ly < lh) ? bar.cov[ly * lw + lx] : 0
            d[y * w + x] = UInt8(255 * (1 - v))
        } }
        guard let image = ctx.makeImage() else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return nil }
        let obs = (req.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        let s = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - Shadow

    static func fitShadow(_ bars: [BarInfo], img: PBuf, B: PBuf, crisp: [Bool], inRect: [Bool]) -> Theme.Shadow? {
        // Region: around the bars, outside them, not ornaments.
        var region = IRect(x0: W, y0: H, x1: 0, y1: 0)
        for b in bars { region = region.union(b.irect.expanded(40)) }
        region = region.clipped(W, H)
        let crispD = dilate(crisp, 2)
        var idx: [Int] = [], obs: [Double] = [], ab: [Double] = []
        region.forEach(W, H) { i in
            guard !inRect[i], !crispD[i] else { return }
            let x = i % W, y = i / W
            // Only pixels within 40 px of some bar.
            guard bars.contains(where: { $0.irect.expanded(40).contains(x, y) && !$0.irect.expanded(1).contains(x, y) }) else { return }
            idx.append(i); obs.append(Double(img.p[i * 4 + 3] - B.p[i * 4 + 3])); ab.append(Double(B.p[i * 4 + 3]))
        }
        guard idx.count > 100 else { return nil }
        let rss0 = obs.reduce(0) { $0 + $1 * $1 }
        let meanExcess = obs.reduce(0, +) / Double(obs.count)
        guard rss0 > 0, meanExcess > 0.004 else { return nil }
        var best: (rss: Double, off: Double, blur: Double, op: Double) = (.infinity, 0, 0, 0)
        let rw = region.width, rh = region.height
        func evaluate(_ off: Double, _ blur: Double) {
            let ctx = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: rw * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            for b in bars {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -off), blur: blur, color: CGColor(gray: 0, alpha: 0.25))
                ctx.setFillColor(b.color.cgColorPremultiplied)
                let r = b.rect
                ctx.fill(CGRect(x: r.x0 - Double(region.x0), y: Double(rh) - (r.y1 - Double(region.y0)), width: r.width, height: r.height))
                ctx.restoreGState()
            }
            let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var smm = 0.0, som = 0.0
            var ms = [Double](repeating: 0, count: idx.count)
            for (k, i) in idx.enumerated() {
                let x = i % W - region.x0, y = i / W - region.y0
                let m = Double(d[(y * rw + x) * 4 + 3]) / 255 * (1 - ab[k])
                ms[k] = m; smm += m * m; som += obs[k] * m
            }
            guard smm > 0 else { return }
            let kf = max(som / smm, 0)
            var rss = 0.0
            for k in 0..<idx.count { let e = obs[k] - kf * ms[k]; rss += e * e }
            if rss < best.rss { best = (rss, off, blur, 0.25 * kf) }
        }
        // Coarse grid, then a finer pass around the best.
        for off in stride(from: 0.0, through: 24, by: 3) {
            for blur in [4.0, 8, 12, 16, 22, 28, 36, 44, 54] { evaluate(off, blur) }
        }
        let (o0, b0) = (best.off, best.blur)
        for off in stride(from: max(o0 - 2, 0), through: o0 + 2, by: 1) {
            for blur in stride(from: max(b0 - 6, 2), through: b0 + 6, by: 2) { evaluate(off, blur) }
        }
        guard best.rss < 0.6 * rss0, best.op >= 0.04 else { return nil }
        return Theme.Shadow(offsetY: best.off, blur: best.blur, opacity: (min(best.op, 1) * 100).rounded() / 100)
    }

    /// Re-estimate bar k's colour assuming the shadows of bars 0…k lie under it; keep it if the
    /// un-composited colours come out more uniform that way.
    static func correctForShadowUnder(_ bars: [BarInfo], _ k: Int, shadow: Theme.Shadow, img: PBuf, B: PBuf) {
        let bar = bars[k]
        let region = bar.irect
        let rw = region.width, rh = region.height
        let ctx = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: rw * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let far = 5000.0   // draw the fill off-canvas; only its shadow lands here
        for b in bars[0...k] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: far, height: -shadow.offsetY), blur: shadow.blur,
                          color: CGColor(gray: 0, alpha: shadow.opacity))
            ctx.setFillColor(b.color.cgColorPremultiplied)
            let r = b.rect
            ctx.fill(CGRect(x: r.x0 - Double(region.x0) - far, y: Double(rh) - (r.y1 - Double(region.y0)), width: r.width, height: r.height))
            ctx.restoreGState()
        }
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var plain: [[Float]] = [[], [], [], []], under: [[Float]] = [[], [], [], []]
        let s = bar.seed
        region.expanded(-2).forEach(W, H) { i in
            let c = img.px(i)
            let u = c.unpremul
            guard abs(u.r - s.r) <= 0.1 && abs(u.g - s.g) <= 0.1 && abs(u.b - s.b) <= 0.1 && abs(u.a - s.a) <= 0.1 else { return }
            let x = i % W - region.x0, y = i / W - region.y0
            let sa = Float(d[(y * rw + x) * 4 + 3]) / 255
            for (list, base) in [(0, B.px(i)), (1, over(RGBA(0, 0, 0, sa), B.px(i)))] {
                let f = invOver(c, base)
                guard f.a > 0.05 else { continue }
                let fu = f.unpremul
                if list == 0 { plain[0].append(fu.r); plain[1].append(fu.g); plain[2].append(fu.b); plain[3].append(f.a) }
                else { under[0].append(fu.r); under[1].append(fu.g); under[2].append(fu.b); under[3].append(f.a) }
            }
        }
        guard under[3].count > 50, plain[3].count > 50 else { return }
        // Spread measured as the 90th-percentile deviation, so the plain case's shadow-darkened edge band counts.
        func spread(_ l: [[Float]]) -> Float {
            l.reduce(0) { acc, ch in
                let m = median(ch); let dev = ch.map { abs($0 - m) }.sorted()
                return acc + dev[dev.count * 9 / 10]
            }
        }
        if spread(under) < spread(plain) * 0.8 {
            let a = median(under[3])
            bar.color = RGBA(median(under[0]) * a, median(under[1]) * a, median(under[2]) * a, a)
        }
    }

    // MARK: - Re-render and compare

    static func renderComposite(theme: Theme, background: CGImage?, foreground: CGImage?, title: String, designation: String) -> PBuf {
        var t = theme
        t.backgroundLayer = nil; t.foregroundLayer = nil
        let r = GraphicRenderer(theme: LoadedTheme(theme: t, folder: nil, isBuiltIn: false))
        r.render(title: title, designation: designation, progress: 1)
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        if let background { ctx.draw(background, in: full) }
        if let bars = r.makeImage() { ctx.draw(bars, in: full) }
        if let foreground { ctx.draw(foreground, in: full) }
        return PBuf.fromContext(ctx, w: W, h: H)
    }

    static func comparisonRegion(_ rects: [IRect], fg: PBuf?) -> IRect {
        var r = IRect(x0: W, y0: H, x1: 0, y1: 0)
        for b in rects { r = r.union(b.expanded(shadowZone)) }
        if let fg {
            for y in 0..<H { for x in 0..<W where fg.p[(y * W + x) * 4 + 3] > 0.05 { r = r.union(IRect(x0: x, y0: y, x1: x + 1, y1: y + 1)) } }
        }
        return r.clipped(W, H)
    }

    static func compare(_ a: PBuf, _ b: PBuf, region: IRect, threshold: Float = 24.0 / 255) -> (mismatch: Double, meanAbs: Double) {
        var bad = 0, total = 0, sum = 0.0
        region.forEach(W, H) { i in
            var m: Float = 0
            for c in 0..<4 { let d = abs(a.p[i * 4 + c] - b.p[i * 4 + c]); m = max(m, d); sum += Double(d) }
            if m > threshold { bad += 1 }
            total += 1
        }
        return total == 0 ? (0, 0) : (Double(bad) / Double(total), sum / Double(total * 4) * 255)
    }

    // MARK: - Small helpers

    static func fontLabel(_ fonts: [String]) -> String {
        CTFontCopyPostScriptName(GraphicRenderer.resolveFont(fonts)) as String
    }

    static func hex(_ c: RGBA, premultiplied: Bool) -> String {
        let u = c.a > 0 ? c.unpremul : RGBA(0, 0, 0, 0)
        return hexString(r: Double(u.r), g: Double(u.g), b: Double(u.b), a: Double(u.a))
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    static func median(_ a: [Float]) -> Float {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); return s[s.count / 2]
    }

    static func mad(_ a: [Float]) -> Float {
        let m = median(a); return median(a.map { abs($0 - m) })
    }

    static func dilate(_ m: [Bool], _ r: Int, w: Int = W, h: Int = H) -> [Bool] {
        var out = m
        for _ in 0..<r {
            let src = out
            for y in 0..<h { for x in 0..<w where !src[y * w + x] {
                if (x > 0 && src[y * w + x - 1]) || (x < w - 1 && src[y * w + x + 1])
                    || (y > 0 && src[(y - 1) * w + x]) || (y < h - 1 && src[(y + 1) * w + x]) { out[y * w + x] = true }
            } }
        }
        return out
    }

    struct Comp {
        var count = 0, x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        var pixels: [Int32] = []
    }

    /// Connected components of `mask` (bounding boxes exclusive at x1/y1).
    static func components(_ mask: [Bool], _ w: Int, _ h: Int, eight: Bool, minCount: Int) -> [Comp] {
        var seen = [Bool](repeating: false, count: w * h)
        var out: [Comp] = []
        var stack: [Int32] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            var c = Comp()
            stack.append(Int32(start)); seen[start] = true
            while let p = stack.popLast() {
                let i = Int(p), x = i % w, y = i / w
                c.count += 1; c.pixels.append(p)
                c.x0 = min(c.x0, x); c.y0 = min(c.y0, y); c.x1 = max(c.x1, x + 1); c.y1 = max(c.y1, y + 1)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    if !eight && dx != 0 && dy != 0 { continue }
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let j = yy * w + xx
                    if mask[j] && !seen[j] { seen[j] = true; stack.append(Int32(j)) }
                } }
            }
            if c.count >= minCount { out.append(c) }
        }
        return out
    }
}

// MARK: - Pixel types

struct RGBA {
    var r: Float, g: Float, b: Float, a: Float
    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float) { self.r = r; self.g = g; self.b = b; self.a = a }
    var unpremul: RGBA { a > 1e-4 ? RGBA(min(r / a, 1), min(g / a, 1), min(b / a, 1), a) : RGBA(0, 0, 0, 0) }
    static func - (l: RGBA, r: RGBA) -> RGBA { RGBA(l.r - r.r, l.g - r.g, l.b - r.b, l.a - r.a) }
    static func + (l: RGBA, r: RGBA) -> RGBA { RGBA(l.r + r.r, l.g + r.g, l.b + r.b, l.a + r.a) }
    static func * (l: RGBA, s: Float) -> RGBA { RGBA(l.r * s, l.g * s, l.b * s, l.a * s) }
    func dot(_ o: RGBA) -> Float { r * o.r + g * o.g + b * o.b + a * o.a }
    var cgColorPremultiplied: CGColor {
        let u = unpremul
        return CGColor(srgbRed: CGFloat(u.r), green: CGFloat(u.g), blue: CGFloat(u.b), alpha: CGFloat(u.a))
    }
}

/// Source-over, premultiplied.
@inline(__always) func over(_ f: RGBA, _ b: RGBA) -> RGBA { f + b * (1 - f.a) }

/// Inverse of source-over: the layer F such that F over U = C (premultiplied).
func invOver(_ c: RGBA, _ u: RGBA) -> RGBA {
    var af: Float
    if u.a < 0.985 {
        af = (c.a - u.a) / (1 - u.a)
    } else {
        af = min(maxDiff(c, u) / 0.15, 1)
    }
    af = min(max(af, 0), 1)
    guard af > 0.004 else { return RGBA(0, 0, 0, 0) }
    var f = c - u * (1 - af)
    f.a = af
    f.r = min(max(f.r, 0), af); f.g = min(max(f.g, 0), af); f.b = min(max(f.b, 0), af)
    return f
}

@inline(__always) func maxDiff(_ a: RGBA, _ b: RGBA) -> Float {
    max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b), abs(a.a - b.a))
}

/// Position of `c` along the segment b→u (t, clamped 0…1) and its distance from it (max channel).
func segmentResidual(_ c: RGBA, _ b: RGBA, _ u: RGBA) -> (t: Float, res: Float) {
    let d = u - b
    let dd = d.dot(d)
    guard dd > 1e-5 else { return (0, maxDiff(c, b)) }
    let t = min(max((c - b).dot(d) / dd, 0), 1)
    return (t, maxDiff(c, b + d * t))
}

struct IRect {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var area: Int { max(width, 0) * max(height, 0) }
    func expanded(_ m: Int) -> IRect { IRect(x0: x0 - m, y0: y0 - m, x1: x1 + m, y1: y1 + m) }
    func clipped(_ w: Int, _ h: Int) -> IRect { IRect(x0: max(x0, 0), y0: max(y0, 0), x1: min(x1, w), y1: min(y1, h)) }
    func union(_ o: IRect) -> IRect { IRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1)) }
    func contains(_ x: Int, _ y: Int) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
    func forEach(_ w: Int, _ h: Int, _ body: (Int) -> Void) {
        let c = clipped(w, h)
        guard c.x1 > c.x0, c.y1 > c.y0 else { return }
        for y in c.y0..<c.y1 { for x in c.x0..<c.x1 { body(y * w + x) } }
    }
}

struct DRect {
    var x0: Double, y0: Double, x1: Double, y1: Double
    var width: Double { x1 - x0 }
    var height: Double { y1 - y0 }
    var cg: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }
}

/// Premultiplied RGBA floats, row 0 at the top.
final class PBuf {
    let w: Int, h: Int
    var p: [Float]
    init(w: Int, h: Int) { self.w = w; self.h = h; p = [Float](repeating: 0, count: w * h * 4) }
    init(w: Int, h: Int, p: [Float]) { self.w = w; self.h = h; self.p = p }

    @inline(__always) func px(_ i: Int) -> RGBA { RGBA(p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]) }
    @inline(__always) func set(_ i: Int, _ c: RGBA) { p[i * 4] = c.r; p[i * 4 + 1] = c.g; p[i * 4 + 2] = c.b; p[i * 4 + 3] = c.a }
    func copy() -> PBuf { PBuf(w: w, h: h, p: p) }

    static func load(_ img: CGImage, w: Int, h: Int) -> PBuf {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return fromContext(ctx, w: w, h: h)
    }

    static func fromContext(_ ctx: CGContext, w: Int, h: Int) -> PBuf {
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let b = PBuf(w: w, h: h)
        let rowBytes = ctx.bytesPerRow
        for y in 0..<h { for x in 0..<(w * 4) { b.p[y * w * 4 + x] = Float(d[y * rowBytes + x]) / 255 } }
        return b
    }

    func makeImage() -> CGImage? {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(w * h) {
            let a = min(max(p[i * 4 + 3], 0), 1)
            let a8 = UInt8((a * 255).rounded())
            d[i * 4 + 3] = a8
            for c in 0..<3 { d[i * 4 + c] = min(UInt8((min(max(p[i * 4 + c], 0), 1) * 255).rounded()), a8) }
        }
        return ctx.makeImage()
    }

    func maxAlpha() -> Float { stride(from: 3, to: p.count, by: 4).reduce(0) { max($0, p[$1]) } }

    func opaqueFraction() -> Double {
        var n = 0
        for i in 0..<(w * h) where p[i * 4 + 3] >= 0.996 { n += 1 }
        return Double(n) / Double(w * h)
    }

    /// Unpremultiplied copy (rgb divided by alpha).
    func unpremultiplied() -> [Float] {
        var u = p
        for i in 0..<(w * h) {
            let a = p[i * 4 + 3]
            if a > 1e-4 { for c in 0..<3 { u[i * 4 + c] = min(p[i * 4 + c] / a, 1) } }
        }
        return u
    }

    /// Median colour of 24×24 patches in the four corners (unpremultiplied rgb).
    func cornerColor() -> (Float, Float, Float) {
        var r: [Float] = [], g: [Float] = [], b: [Float] = []
        for (cx, cy) in [(0, 0), (w - 24, 0), (0, h - 24), (w - 24, h - 24)] {
            for y in cy..<(cy + 24) { for x in cx..<(cx + 24) {
                let c = px(y * w + x).unpremul; r.append(c.r); g.append(c.g); b.append(c.b)
            } }
        }
        return (ThemeExtractor.median(r), ThemeExtractor.median(g), ThemeExtractor.median(b))
    }

    /// Key out an opaque background colour: the least-alpha foreground that reproduces each pixel over it.
    func keyed(_ k: (Float, Float, Float)) -> PBuf {
        let out = PBuf(w: w, h: h)
        let kk = [k.0, k.1, k.2]
        for i in 0..<(w * h) {
            let c = px(i).unpremul
            let cc = [c.r, c.g, c.b]
            var a: Float = 0
            for ch in 0..<3 {
                let d = cc[ch] - kk[ch]
                if d > 0 { a = max(a, kk[ch] < 1 ? d / (1 - kk[ch]) : 1) }
                else if d < 0 { a = max(a, kk[ch] > 0 ? -d / kk[ch] : 1) }
            }
            a = min(a, 1)
            if a < 0.01 { continue }
            // F·a = C − K·(1 − a)
            out.set(i, RGBA(max(cc[0] - kk[0] * (1 - a), 0), max(cc[1] - kk[1] * (1 - a), 0), max(cc[2] - kk[2] * (1 - a), 0), a))
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
