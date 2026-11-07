import Foundation
#if canImport(LifeCGCore)
import LifeCGCore
#endif

// Usage:
//   lt-render <out.png> <title> [designation] [progress 0..1]
//   lt-render --selftest
let args = CommandLine.arguments

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

if args.count >= 2, args[1] == "--selftest" {
    var failures = 0
    func check(_ cond: Bool, _ name: String) { print((cond ? "PASS " : "FAIL ") + name); if !cond { failures += 1 } }

    let store = TitleStore(fileURL: nil)
    check((try? store.show(title: "  ", designation: "x")) == nil, "empty title rejected")
    try! store.show(title: "Ps Luke de Jong", designation: "Lead Pastor")
    check(store.state.onAir && store.state.current?.title == "Ps Luke de Jong", "show puts title on air")
    try! store.show(title: "ps luke de jong ", designation: "lead pastor")
    check(store.state.recent.count == 1, "same title (case/space-insensitive) is deduplicated")
    for i in 0..<25 { try! store.show(title: "Speaker \(i)", designation: "") }
    check(store.state.recent.count == 20, "recent capped at 20")
    check(store.state.recent.first?.title == "Speaker 24", "most recent first")
    store.hide()
    check(!store.state.onAir && store.state.current == nil, "hide")
    store.toggle()
    check(store.state.onAir && store.state.current?.title == "Speaker 24", "toggle re-shows last")
    let id = store.state.recent[3].id
    try! store.showRecent(id: id)
    check(store.state.recent.first?.id == id, "showRecent bumps to top")
    try! store.showRecent(index: 2)
    check(store.state.current?.title == "Speaker 23", "showRecent by index")
    check(TitleEntry.makeID(title: "A", designation: "b") == TitleEntry.makeID(title: " a ", designation: "B"), "stable ids")

    // Auto-clear: fires after N seconds; a later show replaces the timer; hide cancels it.
    func pump(_ t: Double) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    let ac = TitleStore(fileURL: nil)
    check((try? ac.show(title: "X", designation: "", autoClearAfter: 0.2)) != nil && ac.state.autoClearAt != nil, "auto-clear scheduled")
    check((try? ac.show(title: "X", designation: "", autoClearAfter: 0)) == nil, "auto-clear out of range rejected")
    pump(0.4)
    check(!ac.state.onAir && ac.state.autoClearAt == nil, "auto-clear hides after delay")
    try! ac.show(title: "A", designation: "", autoClearAfter: 0.2)
    try! ac.show(title: "B", designation: "")
    pump(0.4)
    check(ac.state.onAir && ac.state.current?.title == "B" && ac.state.autoClearAt == nil, "new show cancels pending auto-clear")
    try! ac.show(title: "C", designation: "", autoClearAfter: 0.2)
    ac.hide(); try! ac.show(title: "D", designation: "")
    pump(0.4)
    check(ac.state.onAir && ac.state.current?.title == "D", "hide cancels pending auto-clear")
    try! ac.showRecent(index: 1, autoClearAfter: 0.2)
    pump(0.4)
    check(!ac.state.onAir, "showRecent supports auto-clear")

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lt-selftest-\(getpid()).json")
    let s1 = TitleStore(fileURL: tmp); try! s1.show(title: "Persisted", designation: "Yes")
    let s2 = TitleStore(fileURL: tmp)
    check(s2.state.recent.first?.title == "Persisted" && !s2.state.onAir, "recent persists, starts off air")
    try? FileManager.default.removeItem(at: tmp)

    let r = GraphicRenderer()
    r.render(title: nil, designation: "", progress: 1)
    let px = r.bytes.assumingMemoryBound(to: UInt8.self)
    check((0..<(1920 * 1080)).allSatisfy { px[$0 * 4 + 3] == 0 }, "off-air frame fully transparent")
    r.render(title: "Ps Luke de Jong", designation: "Lead Pastor", progress: 1)
    let at = { (x: Int, y: Int) in (0..<4).map { px[y * r.bytesPerRow + x * 4 + $0] } }
    check(at(1290, 925)[3] > 200 && at(1290, 925)[2] > 200, "white title box drawn")
    check(at(1530, 1040)[3] > 200 && at(1530, 1040)[2] < 60, "dark designation box drawn")
    check(at(200, 200)[3] == 0, "top-left stays transparent")
    r.render(title: "Ps Luke de Jong", designation: "", progress: 1)
    check(at(1530, 1040)[2] < 60 || at(1530, 1040)[3] < 120, "no designation bar when empty")
    func snapshot(_ t: Transition, _ p: Double) -> [UInt8] {
        r.render(title: "Ps Luke de Jong", designation: "Lead Pastor", progress: p, transition: t)
        return Array(UnsafeBufferPointer(start: px, count: r.bytesPerRow * 1080))
    }
    let reference = snapshot(.slideBoxFadeText, 1)
    for t in Transition.allCases {
        check(snapshot(t, 1) == reference, "transition \(t.rawValue): full frame matches")
        let empty = snapshot(t, 0)
        check(stride(from: 3, to: empty.count, by: 4).allSatisfy { empty[$0] == 0 }, "transition \(t.rawValue): empty at 0")
    }
    let mids = [Transition.slideBoxFadeText, .slideBoxAndText, .fade].map { snapshot($0, 0.5) }
    check(Set(mids.map { $0.hashValue }).count == 3 && !mids.contains(reference), "transitions differ mid-way")
    check(snapshot(.cut, 0.01) == reference, "cut shows the full frame immediately")
    print("fonts:", r.resolvedFontNames())
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

// Headless server (no Syphon): lt-render --serve <port> [store.json]
// Used to integration-test the Companion module and for debugging.
if args.count >= 3, args[1] == "--serve" {
    let store = TitleStore(fileURL: args.count > 3 ? URL(fileURLWithPath: args[3]) : nil)
    let server = ControlServer(store: store)
    let animator = GraphicAnimator(renderer: GraphicRenderer())
    var frames = 0
    animator.onFrame = { _ in frames += 1 }
    server.onLog = { print($0) }
    store.onChange = { st in
        server.broadcast(st)
        animator.apply(st)
        print("state: onAir=\(st.onAir) current=\(st.current?.title ?? "-") recent=\(st.recent.count)")
    }
    try server.start(port: UInt16(args[2]) ?? 9123)
    animator.start()
    signal(SIGINT) { _ in exit(0) }
    dispatchMain()
}

guard args.count >= 3 else { fail("usage: lt-render <out.png> <title> [designation] [progress]  |  lt-render --selftest") }
let r = GraphicRenderer()
r.render(title: args[2], designation: args.count > 3 ? args[3] : "", progress: args.count > 4 ? Double(args[4]) ?? 1 : 1,
         transition: args.count > 5 ? Transition(rawValue: args[5]) ?? .slideBoxFadeText : .slideBoxFadeText)
guard let png = r.pngData() else { fail("encode failed") }
try png.write(to: URL(fileURLWithPath: args[1]))
print("wrote \(args[1])  fonts: \(r.resolvedFontNames())")
