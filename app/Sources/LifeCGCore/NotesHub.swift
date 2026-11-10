import CoreGraphics
import Foundation

/// Glue between `NotesController` (state), the renderer, the main output (`GraphicAnimator`), the
/// cue screen, and the control GUI. Used by the app and by `lt-render --serve`. Main thread.
public final class NotesHub {
    public let controller: NotesController
    public private(set) var themes: [LoadedNotesTheme]
    public let animator: GraphicAnimator?

    /// New cue-screen content (main thread). The app renders and publishes it.
    public var onCue: ((CueRenderer.Content) -> Void)?
    /// Anything the control GUI shows changed.
    public var onStateChange: (() -> Void)?
    /// A notes slide just went live: titles must come off (one replaces the other).
    public var onNotesWentLive: (() -> Void)?
    public var titleOnAir: () -> Bool = { false }

    private var lastLiveKey: String?
    private var lastCue: CueRenderer.Content?
    private var layerCache: [String: CGImage] = [:]
    private var lineCountCache: (key: String, counts: [Int])?
    private var thumbCache: [String: Data] = [:]
    private let thumbQueue = DispatchQueue(label: "org.lifenz.lifecg.thumbs", qos: .userInitiated, attributes: .concurrent)

    public init(controller: NotesController, themes: [LoadedNotesTheme] = NotesThemeLibrary.all(), animator: GraphicAnimator?) {
        self.controller = controller
        self.themes = themes
        self.animator = animator
        controller.availableThemeIDs = Set(themes.map { $0.theme.id })
        if let first = themes.first(where: { $0.theme.id == "central" }) ?? themes.first { controller.fallbackThemeID = first.theme.id }
        controller.onChange = { [weak self] _ in self?.apply() }
    }

    public var theme: LoadedNotesTheme? {
        themes.first { $0.theme.id == controller.themeID } ?? themes.first
    }

    /// Push the current state to the outputs. Called on every controller change.
    public func apply() {
        guard let theme else { onStateChange?(); return }
        let c = controller
        let tid = theme.theme.id
        let bg = layerCache[tid] ?? NotesRenderer.renderLayers(theme)
        layerCache[tid] = bg
        if let s = c.liveSlide, let svc = c.loaded {
            let key = "\(svc.id)|\(svc.version)|\(tid)|\(c.liveIndex!)|\(s.id)"
            if key != lastLiveKey {
                lastLiveKey = key
                animator?.setNotes(background: bg, bgKey: tid, text: NotesRenderer.renderText(s, theme: theme.theme), textKey: key)
                onNotesWentLive?()
            }
        } else if lastLiveKey != nil {
            lastLiveKey = nil
            animator?.setNotes(background: bg, bgKey: tid, text: nil, textKey: nil)
        } else {
            animator?.setNotes(background: bg, bgKey: tid, text: nil, textKey: nil)
        }
        let footer: String = {
            guard let svc = c.loaded else { return "No notes loaded" }
            var parts = [svc.label ?? svc.campusName ?? svc.campusId, svc.title ?? ""].filter { !$0.isEmpty }
            if let i = c.liveIndex { parts.append("slide \(i + 1) of \(c.slides.count)") }
            return parts.joined(separator: "  ·  ")
        }()
        let cue = CueRenderer.Content(current: c.liveSlide, next: c.nextSlide, footer: footer)
        if cue != lastCue { lastCue = cue; onCue?(cue) }
        onStateChange?()
    }

    public var cueContent: CueRenderer.Content {
        lastCue ?? CueRenderer.Content(current: nil, next: nil, footer: "")
    }

    // MARK: Control GUI

    public func lineCounts() -> [Int] {
        guard let theme, let svc = controller.loaded else { return [] }
        let key = "\(svc.id)|\(svc.version)|\(theme.theme.id)"
        if let c = lineCountCache, c.key == key { return c.counts }
        let counts = svc.slides.map { NotesRenderer.layout($0, theme: theme.theme).lineCount }
        lineCountCache = (key, counts)
        return counts
    }

    public func stateJSON() -> [String: Any] {
        var o = controller.jsonObject(themes: themes.map { ($0.theme.id, $0.theme.name) }, titleOnAir: titleOnAir(),
                                      lineCounts: lineCounts())
        if let t = theme {
            o["maxLines"] = Dictionary(uniqueKeysWithValues: t.theme.styles.map { ($0.key, $0.value.maxLines) })
        }
        return o
    }

    /// PNG thumbnail (lower-third crop) of slide `index` in the current theme, rendered off the main thread.
    public func thumbnail(_ index: Int, completion: @escaping (Data?) -> Void) {
        guard let theme, let svc = controller.loaded, svc.slides.indices.contains(index) else { completion(nil); return }
        let key = "\(svc.id)|\(svc.version)|\(theme.theme.id)|\(index)"
        if let d = thumbCache[key] { completion(d); return }
        let slide = svc.slides[index]
        thumbQueue.async {
            let data = NotesRenderer.thumbnail(slide, theme: theme, scale: 0.5).flatMap(GraphicRenderer.png)
            DispatchQueue.main.async {
                if let data {
                    if self.thumbCache.count > 400 { self.thumbCache.removeAll() }
                    self.thumbCache[key] = data
                }
                completion(data)
            }
        }
    }
}
