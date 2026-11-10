import CoreGraphics
import CoreText
import Foundation
#if canImport(LifeCGCore)
import LifeCGCore
#endif

// lt-render --notes <themeId> <slides.json> <outdir> [--text-only] [--cue]
//   slides.json: a service package (FORMAT.md) or a bare array of slides.
//   Writes <outdir>/<n>.png (full frame, layers + text) and, with --cue, <n>-cue.png.
func runNotesCommand(_ args: [String]) -> Never {
    guard args.count >= 5 else { fail("usage: lt-render --notes <themeId> <slides.json> <outdir> [--text-only] [--cue]") }
    let themes = NotesThemeLibrary.all()
    guard let theme = themes.first(where: { $0.theme.id == args[2] }) else {
        fail("unknown notes theme \(args[2]); have \(themes.map { $0.theme.id })")
    }
    let data = (try? Data(contentsOf: URL(fileURLWithPath: args[3]))) ?? Data()
    let slides: [NoteSlide]
    if let p = try? JSONDecoder().decode(ServicePackage.self, from: data) { slides = p.slides }
    else if let s = try? JSONDecoder().decode([NoteSlide].self, from: data) { slides = s }
    else { fail("could not read slides from \(args[3])") }
    let out = URL(fileURLWithPath: args[4])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let textOnly = args.contains("--text-only"), cue = args.contains("--cue")
    print("fonts installed:", NotesRenderer.fontsInstalled(theme.theme))
    for (i, s) in slides.enumerated() {
        let img = textOnly ? NotesRenderer.renderText(s, theme: theme.theme) : NotesRenderer.renderComposite(s, theme: theme)
        let lay = NotesRenderer.layout(s, theme: theme.theme)
        let name = "\(i + 1).png"
        if let img, let png = GraphicRenderer.png(img) { try? png.write(to: out.appendingPathComponent(name)) }
        if cue, let c = CueRenderer.render(.init(current: s, next: i + 1 < slides.count ? slides[i + 1] : nil,
                                                 footer: "Slide \(i + 1) of \(slides.count)")),
           let png = GraphicRenderer.png(c) {
            try? png.write(to: out.appendingPathComponent("\(i + 1)-cue.png"))
        }
        let warn = lay.lineCount > lay.style.maxLines ? "  ⚠︎ \(lay.lineCount) lines > \(lay.style.maxLines)" : ""
        print("\(name)  \(s.style)  \(lay.lineCount) lines  top=\(Int(lay.top))\(warn)")
    }
    exit(0)
}

func notesSelfTests(_ check: (Bool, String) -> Void) {
    func slide(_ id: String, _ text: String, style: String = "small") -> NoteSlide {
        NoteSlide(id: id, kind: "scripture", style: style, runs: [NoteRun("John 4:4-10 (NLT)", bold: true), NoteRun("\n" + text)])
    }
    func pkg(_ v: Int, _ ids: [String]) -> Data {
        let p = ServicePackage(id: "svc", campusId: "central", campusName: nil, label: "Central AM", startsAt: nil, themeId: "central",
                               messageId: nil, title: "T", speaker: nil, version: v, updatedAt: nil,
                               slides: ids.map { slide($0, "4 He had to go through Samaria.") })
        return try! JSONEncoder().encode(p)
    }
    let n = NotesController(cacheDir: nil)
    try! n.importPackage(pkg(1, ["a", "b", "c", "d"]))
    check(n.liveIndex == nil && n.nextIndex == 0, "notes: loaded, nothing live, next = first")
    n.goLive(1)
    check(n.liveIndex == 1 && n.nextIndex == 2, "notes: live 2, next 3")
    n.preview(3)
    check(n.liveIndex == 1 && n.nextIndex == 3, "notes: preview sets cue next without going live")
    n.goLive(2)
    check(n.previewIndex == nil && n.nextIndex == 3, "notes: going live clears preview")
    n.clear()
    check(n.liveIndex == nil && n.nextIndex == 3, "notes: clear keeps cue next")
    n.clearAll()
    check(n.liveIndex == nil && n.nextIndex == nil, "notes: clear all blanks cue next")
    n.goNext()
    check(n.liveIndex == 3, "notes: next after clear all continues after the last live slide")
    // Update keeps the operator's place by slide id.
    n.goLive(1)   // "b"
    let upd = try! JSONDecoder().decode(ServicePackage.self, from: pkg(2, ["x", "a", "b", "c", "d"]))
    n.setPendingForTesting(upd)
    n.applyUpdate()
    check(n.loaded?.version == 2 && n.liveIndex == 2 && n.liveSlide?.id == "b", "notes: update keeps the live slide by id")

    // Layout rules (needs the theme files).
    if let t = NotesThemeLibrary.all().first(where: { $0.theme.id == "central" }) {
        let one = NotesRenderer.layout(NoteSlide(id: "p", kind: "point", style: "big", runs: [NoteRun("FRESH OIL TRANSFORMS HOW I SEE MYSELF", bold: true)]), theme: t.theme)
        check(one.lineCount == 1, "notes: short point fits one big line")
        let s = slide("s", "4 He had to go through Samaria on the way. 5 Eventually he came to the Samaritan village of Sychar, near the field that Jacob gave to his son\u{00A0}Joseph.")
        let lay = NotesRenderer.layout(s, theme: t.theme)
        check(lay.lineCount == 4, "notes: John 4:4-5 is heading + 3 lines (as in the Oct 2026 deck)")
        let last = lay.lines.last.map { CTLineGetGlyphCount($0.line) } ?? 0
        check(last > 8, "notes: no-break space keeps the last two words together")
        check(abs(lay.top + lay.blockHeight - (753.138 + 290.233)) < 0.01, "notes: bottom-aligned in the Central box")
    } else {
        check(false, "notes themes found")
    }
}
