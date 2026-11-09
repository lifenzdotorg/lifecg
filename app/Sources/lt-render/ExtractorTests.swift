import CoreGraphics
import CoreText
import Foundation
#if canImport(LifeCGCore)
import LifeCGCore
#endif

// Self-tests and CLI command for ThemeExtractor ("theme from a sample PNG").
//
//   lt-render --extract <sample.png> <outdir> [titleText] [designationText]
//             [--title-fonts A,B] [--designation-fonts A,B] [--no-ocr]
//
// Comparison images from the self-tests go to $LT_EXTRACT_OUT (default: a temp folder).

private let extractorRepoRoot: URL = {
    // .../app/Sources/lt-render/ExtractorTests.swift → repo root (parent of app)
    let here = URL(fileURLWithPath: #filePath)
    let fromSource = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: fromSource.appendingPathComponent("docs/reference-composite.png").path) { return fromSource }
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<4 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("docs/reference-composite.png").path) { return dir }
        dir = dir.deletingLastPathComponent()
    }
    return fromSource
}()

private let extractorOutDir: URL = {
    let env = ProcessInfo.processInfo.environment["LT_EXTRACT_OUT"]
    let url = env.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("lt-extract-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

private func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

private func rgba(_ hex: String) -> [Int] {
    var h = hex; if h.hasPrefix("#") { h.removeFirst() }
    if h.count == 6 { h += "FF" }
    let v = UInt32(h, radix: 16) ?? 0
    return [Int(v >> 24 & 0xFF), Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF)]
}

private func colorsNear(_ a: String, _ b: String, _ tol: Int) -> Bool {
    zip(rgba(a), rgba(b)).allSatisfy { abs($0 - $1) <= tol }
}

private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

private func describe(_ b: Theme.Bar) -> String {
    "anchorX \(fmt(b.anchorX)) top \(fmt(b.top)) bottom \(fmt(b.bottom)) baseline \(fmt(b.baseline)) "
        + "padOuter \(fmt(b.padOuter)) padInner \(fmt(b.padInner)) cap \(fmt(b.capHeight)) tracking \(String(format: "%.4f", b.tracking)) "
        + "color \(b.color) text \(b.textColor) upper \(b.uppercase) shadow \(b.shadow.map { "(\(fmt($0.offsetY)), \(fmt($0.blur)), \(fmt($0.opacity)))" } ?? "none")"
}

/// Compare one extracted bar with the expected one; returns the failing fields.
private func barErrors(_ got: Theme.Bar, _ want: Theme.Bar, pos: Double, pad: Double, color: Int, cap: Double, tracking: Double,
                       baseline: Double? = nil) -> [String] {
    var e: [String] = []
    if !near(got.anchorX, want.anchorX, pos) { e.append("anchorX \(fmt(got.anchorX)) vs \(fmt(want.anchorX))") }
    if !near(got.top, want.top, pos) { e.append("top \(fmt(got.top)) vs \(fmt(want.top))") }
    if !near(got.bottom, want.bottom, pos) { e.append("bottom \(fmt(got.bottom)) vs \(fmt(want.bottom))") }
    if !near(got.baseline, want.baseline, baseline ?? pos) { e.append("baseline \(fmt(got.baseline)) vs \(fmt(want.baseline))") }
    if !near(got.padOuter, want.padOuter, pad) { e.append("padOuter \(fmt(got.padOuter)) vs \(fmt(want.padOuter))") }
    if !near(got.padInner, want.padInner, pad) { e.append("padInner \(fmt(got.padInner)) vs \(fmt(want.padInner))") }
    if !colorsNear(got.color, want.color, color) { e.append("color \(got.color) vs \(want.color)") }
    if !colorsNear(got.textColor, want.textColor, color) { e.append("textColor \(got.textColor) vs \(want.textColor)") }
    if !near(got.capHeight, want.capHeight, cap) { e.append("cap \(fmt(got.capHeight)) vs \(fmt(want.capHeight))") }
    if !near(got.tracking, want.tracking, tracking) { e.append("tracking \(got.tracking) vs \(want.tracking)") }
    if got.uppercase != want.uppercase { e.append("uppercase \(got.uppercase) vs \(want.uppercase)") }
    if (got.shadow == nil) != (want.shadow == nil) { e.append("shadow \(got.shadow != nil) vs \(want.shadow != nil)") }
    return e
}

// MARK: - Images

private func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

private func checkerboard(_ ctx: CGContext, _ rect: CGRect) {
    ctx.saveGState()
    ctx.clip(to: rect)
    let s = 12.0
    var y = rect.minY
    var row = 0
    while y < rect.maxY {
        var x = rect.minX, col = row
        while x < rect.maxX {
            ctx.setFillColor(gray: col % 2 == 0 ? 0.78 : 0.47, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: s, height: s))
            x += s; col += 1
        }
        y += s; row += 1
    }
    ctx.restoreGState()
}

/// Crops (top-left `crop`) of several full frames stacked vertically, each on a checkerboard, with labels.
private func sideBySide(_ frames: [(String, CGImage)], crop: CGRect) -> CGImage? {
    let label = 26.0
    let w = Int(crop.width), rowH = Int(crop.height + label)
    let ctx = makeContext(w, rowH * frames.count)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: rowH * frames.count))
    for (k, (name, img)) in frames.enumerated() {
        let top = Double(rowH * (frames.count - 1 - k))   // CG y of this row's bottom
        let area = CGRect(x: 0, y: top, width: crop.width, height: crop.height)
        checkerboard(ctx, area)
        ctx.saveGState()
        ctx.clip(to: area)
        // Place the full frame so that `crop` lands in `area`.
        ctx.draw(img, in: CGRect(x: -crop.minX, y: top - (1080 - crop.maxY), width: 1920, height: 1080))
        ctx.restoreGState()
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 16, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        ctx.textPosition = CGPoint(x: 8, y: top + crop.height + 7)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: attrs)), ctx)
    }
    return ctx.makeImage()
}

private func flattenOnWhite(_ img: CGImage) -> CGImage? {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.makeImage()
}

/// Render a theme (with its layer images) through the real renderer.
private func renderSample(_ theme: Theme, background: CGImage?, foreground: CGImage?, title: String, designation: String) -> CGImage? {
    var t = theme
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lt-extract-synth-\(getpid())-\(theme.id)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    t.backgroundLayer = nil; t.foregroundLayer = nil
    if let background { try? writePNG(background, folder.appendingPathComponent("background.png")); t.backgroundLayer = "background.png" }
    if let foreground { try? writePNG(foreground, folder.appendingPathComponent("foreground.png")); t.foregroundLayer = "foreground.png" }
    let r = GraphicRenderer(theme: LoadedTheme(theme: t, folder: folder, isBuiltIn: false))
    r.render(title: title, designation: designation, progress: 1)
    let img = r.makeImage()
    try? FileManager.default.removeItem(at: folder)
    return img
}

private func syntheticLayers(anchor: Theme.Anchor, ornamentAt: CGRect?, ornamentColor: CGColor) -> (CGImage?, CGImage?) {
    let bg = makeContext(1920, 1080)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.05, green: 0.05, blue: 0.2, alpha: 0.45),
                                                     CGColor(srgbRed: 0.05, green: 0.05, blue: 0.2, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    let corner = CGPoint(x: anchor == .left ? 0 : 1920, y: 0)
    bg.drawRadialGradient(grad, startCenter: corner, startRadius: 0, endCenter: corner, endRadius: 700, options: [])
    var fgImg: CGImage?
    if let o = ornamentAt {
        let fg = makeContext(1920, 1080)
        fg.setFillColor(ornamentColor)
        // Top-left rect → CG
        let r = CGRect(x: o.minX, y: 1080 - o.maxY, width: o.width, height: o.height)
        fg.fill(r.insetBy(dx: 0, dy: o.height / 3))
        fg.fill(r.insetBy(dx: o.width / 3, dy: 0))
        fgImg = fg.makeImage()
    }
    return (bg.makeImage(), fgImg)
}

// MARK: - Self-tests

func extractorSelfTests(_ check: (Bool, String) -> Void) {
    let root = extractorRepoRoot
    print("-- theme extractor (comparison images in \(extractorOutDir.path))")
    let life = Theme.life
    let crop = CGRect(x: 1150, y: 840, width: 770, height: 240)

    // 1. Reference sample with its texts.
    guard let sample = loadPNG(root.appendingPathComponent("docs/reference-composite.png")) else {
        check(false, "extractor: reference-composite.png found"); return
    }
    let t0 = Date()
    guard let ex = try? ThemeExtractor.extract(sample: sample, id: "ref", name: "Reference", titleText: "Ps Luke de Jong",
                                               designationText: "Lead Pastor", titleFonts: life.title.fonts,
                                               designationFonts: life.designation!.fonts) else {
        check(false, "extractor: reference extracts"); return
    }
    print(String(format: "  reference extracted in %.2fs", Date().timeIntervalSince(t0)))
    print("  title:       " + describe(ex.theme.title))
    print("  life title:  " + describe(life.title))
    if let d = ex.theme.designation { print("  desig:       " + describe(d)) }
    print("  life desig:  " + describe(life.designation!))
    print("  fit: title \(ex.titleFontFit.map(fmt) ?? "-") desig \(ex.designationFontFit.map(fmt) ?? "-")  warnings: \(ex.warnings)")
    check(ex.theme.anchor == .right, "extractor: reference anchored right")
    // Two Theme.life values don't match the reference pixels, so those are checked against the pixels:
    //  - title padOuter: the "g" stem ends at x = 1773.5 in the reference (the built-in theme draws it at
    //    1767), i.e. 21.5 px from the bar's edge at 1795, not 26;
    //  - designation text: the reference's white text never exceeds 247 and plateaus around 240.
    var lifeTitle = life.title, lifeDesig = life.designation!
    lifeTitle.padOuter = 1795 - 1773.5
    lifeDesig.textColor = "#F0F0F0FF"
    print("  (checking title padOuter against 21.5 and designation text against #F0F0F0, measured from the reference pixels)")
    let te = barErrors(ex.theme.title, lifeTitle, pos: 2, pad: 3, color: 6, cap: 1.5, tracking: 0.01)
    check(te.isEmpty, "extractor: reference title bar matches Theme.life " + te.joined(separator: ", "))
    if let d = ex.theme.designation {
        let de = barErrors(d, lifeDesig, pos: 2, pad: 3, color: 6, cap: 1.5, tracking: 0.01)
        check(de.isEmpty, "extractor: reference designation bar matches Theme.life " + de.joined(separator: ", "))
    } else {
        check(false, "extractor: reference designation bar found")
    }
    check(ex.background != nil && ex.foreground != nil, "extractor: reference has background and foreground layers")
    if let preview = ThemeExtractor.renderPreview(ex, title: "Ps Luke de Jong", designation: "Lead Pastor") {
        let mm = ThemeExtractor.mismatch(sample, preview)
        // The built-in theme rendered the same way, as a yardstick (the reference came from a browser).
        let builtIn = renderSample(life, background: loadPNG(root.appendingPathComponent("app/Themes/life/background.png")),
                                   foreground: loadPNG(root.appendingPathComponent("app/Themes/life/foreground.png")),
                                   title: "Ps Luke de Jong", designation: "Lead Pastor")
        let mmB = builtIn.map { ThemeExtractor.mismatch(sample, $0) }
        print(String(format: "  re-render vs sample: matchScore %.3f, %.2f%% of pixels differ by >24 (mean abs %.2f); built-in theme: %.2f%%",
                     ex.matchScore ?? -1, mm.fraction * 100, mm.meanAbs, (mmB?.fraction ?? -1) * 100))
        check((ex.matchScore ?? 0) > 0.95 && mm.fraction < 0.05, "extractor: reference re-render matches sample")
        let other = ThemeExtractor.renderPreview(ex, title: "Jo Bloggs", designation: "Worship & Creative Arts Director")
        var frames: [(String, CGImage)] = [("sample", sample), ("re-render with extracted theme", preview)]
        if let builtIn { frames.append(("built-in LIFE theme", builtIn)) }
        if let other { frames.append(("extracted theme, other text", other)) }
        if let img = sideBySide(frames, crop: crop) {
            try? writePNG(img, extractorOutDir.appendingPathComponent("compare-reference.png"))
        }
        if let bg = ex.background, let fg = ex.foreground,
           let lay = sideBySide([("extracted background", bg), ("extracted foreground", fg)], crop: crop) {
            try? writePNG(lay, extractorOutDir.appendingPathComponent("layers-reference.png"))
        }
        // Extracted layers vs the hand-made ones.
        if let bgT = loadPNG(root.appendingPathComponent("app/Themes/life/background.png")), let bg = ex.background {
            let zone = CGRect(x: 1230, y: 870, width: 690, height: 210)
            let m = ThemeExtractor.mismatch(bgT, bg, threshold: 8, region: zone)
            let all = ThemeExtractor.mismatch(bgT, bg, threshold: 8, region: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            print(String(format: "  background layer vs built-in: around the bars %.2f%% differ by >8 (mean abs %.2f); whole frame %.2f%% (mean abs %.2f)",
                         m.fraction * 100, m.meanAbs, all.fraction * 100, all.meanAbs))
            check(m.fraction < 0.05, "extractor: reference background layer close to the built-in one under the bars")
        }
    }

    // 2. Round trips with synthetic themes.
    struct Case { var theme: Theme; var title: String; var desig: String; var layers: (CGImage?, CGImage?) }
    var cases: [Case] = []
    do {
        let t = Theme(id: "synth-left", name: "Left blue", anchor: .left,
                      title: Theme.Bar(anchorX: 120, top: 852, bottom: 928, padOuter: 30, padInner: 34, baseline: 905,
                                       color: "#1F4E9CF2", textColor: "#FFFFFFFF", fonts: ["HelveticaNeue-Bold"],
                                       capHeight: 36, tracking: 0.02, shadow: Theme.Shadow(offsetY: 6, blur: 12, opacity: 0.35)),
                      designation: Theme.Bar(anchorX: 120, top: 928, bottom: 974, padOuter: 30, padInner: 26, baseline: 958,
                                             color: "#F2C230FF", textColor: "#1A1A1AFF", fonts: ["HelveticaNeue"],
                                             capHeight: 20, tracking: 0.05, shadow: Theme.Shadow(offsetY: 6, blur: 12, opacity: 0.35)))
        cases.append(Case(theme: t, title: "Rev. Dr Anna Whitfield", desig: "Senior Minister",
                          layers: syntheticLayers(anchor: .left, ornamentAt: CGRect(x: 100, y: 832, width: 40, height: 40),
                                                  ornamentColor: CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))))
    }
    do {
        let t = Theme(id: "synth-single", name: "Single red", anchor: .right,
                      title: Theme.Bar(anchorX: 1840.5, top: 900, bottom: 968, padOuter: 40, padInner: 28, baseline: 947,
                                       color: "#C8102EFF", textColor: "#FFFFFFFF", fonts: ["AvenirNext-DemiBold"],
                                       capHeight: 31, tracking: 0, shadow: nil),
                      designation: nil)
        cases.append(Case(theme: t, title: "Maria Gonzalez", desig: "", layers: (nil, nil)))
    }
    do {
        let t = Theme(id: "synth-upper", name: "Upper green", anchor: .right,
                      title: Theme.Bar(anchorX: 1780, top: 880, bottom: 940, padOuter: 22, padInner: 22, baseline: 922,
                                       color: "#0B3D2EE0", textColor: "#F5F5F5FF", fonts: ["AvenirNext-Bold"],
                                       capHeight: 26, tracking: 0.12, uppercase: true, shadow: Theme.Shadow()),
                      designation: Theme.Bar(anchorX: 1780, top: 940, bottom: 984, padOuter: 22, padInner: 40, baseline: 969,
                                             color: "#FFFFFFD0", textColor: "#0B3D2EFF", fonts: ["AvenirNext-Regular"],
                                             capHeight: 18, tracking: 0.02, shadow: Theme.Shadow()))
        cases.append(Case(theme: t, title: "Sam Taylor-Wood", desig: "Youth Director",
                          layers: syntheticLayers(anchor: .right, ornamentAt: CGRect(x: 1766, y: 862, width: 30, height: 30),
                                                  ornamentColor: CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1))))
    }
    for c in cases {
        guard let s = renderSample(c.theme, background: c.layers.0, foreground: c.layers.1, title: c.title, designation: c.desig) else {
            check(false, "extractor: synthetic \(c.theme.id) renders"); continue
        }
        let fontsT = c.theme.title.fonts, fontsD = c.theme.designation?.fonts ?? []
        guard let e = try? ThemeExtractor.extract(sample: s, id: c.theme.id, name: c.theme.name, titleText: c.title,
                                                  designationText: c.desig.isEmpty ? nil : c.desig,
                                                  titleFonts: fontsT, designationFonts: fontsD) else {
            check(false, "extractor: synthetic \(c.theme.id) extracts"); continue
        }
        print("  [\(c.theme.id)] title: " + describe(e.theme.title))
        print("  [\(c.theme.id)] want:  " + describe(c.theme.title))
        if let d = e.theme.designation { print("  [\(c.theme.id)] desig: " + describe(d)) }
        if let d = c.theme.designation { print("  [\(c.theme.id)] want:  " + describe(d)) }
        check(e.theme.anchor == c.theme.anchor, "extractor: synthetic \(c.theme.id) anchor")
        let errs = barErrors(e.theme.title, c.theme.title, pos: 1.5, pad: 2, color: 5, cap: 1, tracking: 0.01)
        check(errs.isEmpty, "extractor: synthetic \(c.theme.id) title round-trips " + errs.joined(separator: ", "))
        switch (e.theme.designation, c.theme.designation) {
        case (nil, nil): check(true, "extractor: synthetic \(c.theme.id) has no designation bar")
        case let (g?, w?):
            let de = barErrors(g, w, pos: 1.5, pad: 2, color: 5, cap: 1, tracking: 0.01)
            check(de.isEmpty, "extractor: synthetic \(c.theme.id) designation round-trips " + de.joined(separator: ", "))
        default: check(false, "extractor: synthetic \(c.theme.id) designation presence")
        }
        if let p = ThemeExtractor.renderPreview(e, title: c.title, designation: c.desig) {
            let mm = ThemeExtractor.mismatch(s, p)
            print(String(format: "  [\(c.theme.id)] re-render: %.2f%% of pixels differ by >24 (mean abs %.2f)", mm.fraction * 100, mm.meanAbs))
            check(mm.fraction < 0.02, "extractor: synthetic \(c.theme.id) re-render matches")
            let other = ThemeExtractor.renderPreview(e, title: "Bo Li", designation: c.desig.isEmpty ? "" : "Guest")
            let truthOther = renderSample(c.theme, background: c.layers.0, foreground: c.layers.1, title: "Bo Li",
                                          designation: c.desig.isEmpty ? "" : "Guest")
            if let other, let truthOther {
                let mo = ThemeExtractor.mismatch(truthOther, other)
                print(String(format: "  [\(c.theme.id)] short name vs truth: %.2f%% differ by >24", mo.fraction * 100))
                check(mo.fraction < 0.03, "extractor: synthetic \(c.theme.id) layers work for a shorter name")
                let cropS = c.theme.anchor == .left ? CGRect(x: 0, y: 800, width: 900, height: 280) : CGRect(x: 1020, y: 800, width: 900, height: 280)
                if let img = sideBySide([("sample", s), ("re-render", p), ("truth: short name", truthOther), ("extracted: short name", other)], crop: cropS) {
                    try? writePNG(img, extractorOutDir.appendingPathComponent("compare-\(c.theme.id).png"))
                }
            }
        }
    }

    // 3. No sample texts: still works, warns, geometry close (with and without OCR).
    for ocr in [false, true] {
        guard let e = try? ThemeExtractor.extract(sample: sample, id: "ref-notext", name: "No text", titleText: nil, designationText: nil,
                                                  titleFonts: life.title.fonts, designationFonts: life.designation!.fonts, useOCR: ocr) else {
            check(false, "extractor: no-text extraction (ocr \(ocr)) succeeds"); continue
        }
        let label = ocr ? "OCR" : "profile"
        print("  [no text, \(label)] title: " + describe(e.theme.title))
        if let d = e.theme.designation { print("  [no text, \(label)] desig: " + describe(d)) }
        print("  [no text, \(label)] read: \(e.titleTextUsed ?? "-") / \(e.designationTextUsed ?? "-")  warnings: \(e.warnings)")
        check(!e.warnings.isEmpty, "extractor: no-text (\(label)) warns")
        let capTol = ocr ? 1.5 : 4.0, trTol = ocr ? 0.01 : 1.0, padTol = ocr ? 3.0 : 4.0
        let te = barErrors(e.theme.title, lifeTitle, pos: 2, pad: padTol, color: 6, cap: capTol, tracking: trTol, baseline: ocr ? 2 : 3)
        check(te.isEmpty, "extractor: no-text (\(label)) title geometry close " + te.joined(separator: ", "))
        if let d = e.theme.designation {
            let de = barErrors(d, lifeDesig, pos: 2, pad: padTol, color: 6, cap: capTol, tracking: trTol, baseline: ocr ? 2 : 3)
            check(de.isEmpty, "extractor: no-text (\(label)) designation geometry close " + de.joined(separator: ", "))
        } else { check(false, "extractor: no-text (\(label)) designation found") }
    }

    // 4. Opaque sample (reference flattened on white).
    if let flat = flattenOnWhite(sample) {
        do {
            let e = try ThemeExtractor.extract(sample: flat, id: "opaque", name: "Opaque", titleText: "Ps Luke de Jong",
                                               designationText: "Lead Pastor", titleFonts: life.title.fonts,
                                               designationFonts: life.designation!.fonts)
            print("  [opaque] title: " + describe(e.theme.title))
            if let d = e.theme.designation { print("  [opaque] desig: " + describe(d)) }
            print("  [opaque] warnings: \(e.warnings)")
            check(e.warnings.contains { $0.contains("transparency") }, "extractor: opaque sample succeeds with a warning")
            if let p = ThemeExtractor.renderPreview(e, title: e.titleTextUsed ?? "", designation: e.designationTextUsed ?? ""),
               let img = sideBySide([("opaque sample", flat), ("re-render", p)], crop: crop) {
                try? writePNG(img, extractorOutDir.appendingPathComponent("compare-opaque.png"))
            }
        } catch {
            check(false, "extractor: opaque sample succeeds (\(error))")
        }
    }

    // 5. Blank images throw.
    let blank = makeContext(1920, 1080).makeImage()!
    check((try? ThemeExtractor.extract(sample: blank, id: "b", name: "b", titleText: nil, designationText: nil,
                                       titleFonts: [], designationFonts: [])) == nil, "extractor: transparent image throws")
    let white = flattenOnWhite(blank)!
    do {
        _ = try ThemeExtractor.extract(sample: white, id: "w", name: "w", titleText: nil, designationText: nil, titleFonts: [], designationFonts: [])
        check(false, "extractor: plain white image throws")
    } catch {
        check(true, "extractor: plain white image throws (\(error.localizedDescription.prefix(40))…)")
    }
}

// MARK: - CLI

func runExtractCommand(_ args: [String]) -> Never {
    func die(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }
    var rest = args
    if let i = rest.firstIndex(of: "--extract") { rest = Array(rest[(i + 1)...]) }
    var titleFonts = Theme.life.title.fonts, desigFonts = Theme.life.designation!.fonts, useOCR = true
    var positional: [String] = []
    var k = 0
    while k < rest.count {
        switch rest[k] {
        case "--title-fonts" where k + 1 < rest.count: titleFonts = rest[k + 1].split(separator: ",").map(String.init); k += 2
        case "--designation-fonts" where k + 1 < rest.count: desigFonts = rest[k + 1].split(separator: ",").map(String.init); k += 2
        case "--no-ocr": useOCR = false; k += 1
        default: positional.append(rest[k]); k += 1
        }
    }
    guard positional.count >= 2 else {
        die("usage: lt-render --extract <sample.png> <outdir> [titleText] [designationText] [--title-fonts A,B] [--designation-fonts A,B] [--no-ocr]")
    }
    let sampleURL = URL(fileURLWithPath: positional[0]), out = URL(fileURLWithPath: positional[1], isDirectory: true)
    let title = positional.count > 2 ? positional[2] : nil, desig = positional.count > 3 ? positional[3] : nil
    guard let sample = loadPNG(sampleURL) else { die("can't read \(sampleURL.path)") }
    let name = sampleURL.deletingPathExtension().lastPathComponent
    let e: ThemeExtraction
    do {
        e = try ThemeExtractor.extract(sample: sample, id: name, name: name, titleText: title, designationText: desig,
                                       titleFonts: titleFonts, designationFonts: desigFonts, useOCR: useOCR)
    } catch { die("extract failed: \(error.localizedDescription)") }
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var theme = e.theme
        theme.notes = "Imported from \(sampleURL.lastPathComponent)"
        if let bg = e.background { try writePNG(bg, out.appendingPathComponent("background.png")) }
        if let fg = e.foreground { try writePNG(fg, out.appendingPathComponent("foreground.png")) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(theme).write(to: out.appendingPathComponent("theme.json"))
        let pt = e.titleTextUsed ?? "Ps Luke de Jong", pd = e.designation(orDefault: "Lead Pastor")
        if let p = ThemeExtractor.renderPreview(e, title: pt, designation: pd) {
            try writePNG(p, out.appendingPathComponent("preview.png"))
        }
    } catch { die("write failed: \(error.localizedDescription)") }
    print("anchor: \(e.theme.anchor.rawValue)")
    print("title bar:       \(e.titleBar)  ink \(e.titleInk)")
    print("  " + describe(e.theme.title))
    if let d = e.theme.designation, let r = e.designationBar {
        print("designation bar: \(r)  ink \(e.designationInk ?? .zero)")
        print("  " + describe(d))
    } else {
        print("designation bar: none")
    }
    print("layers: background \(e.background != nil ? "yes" : "no"), foreground \(e.foreground != nil ? "yes" : "no")")
    print("text used: \(e.titleTextUsed ?? "-") / \(e.designationTextUsed ?? "-")  font fit: \(e.titleFontFit.map(fmt) ?? "-") / \(e.designationFontFit.map(fmt) ?? "-")")
    if let m = e.matchScore { print(String(format: "match score: %.3f", m)) }
    for w in e.warnings { print("warning: \(w)") }
    print("wrote \(out.path)")
    exit(0)
}

private extension ThemeExtraction {
    func designation(orDefault d: String) -> String {
        theme.designation == nil ? "" : (designationTextUsed ?? d)
    }
}
