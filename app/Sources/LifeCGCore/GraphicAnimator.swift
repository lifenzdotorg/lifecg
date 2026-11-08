import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// Turns on-air state changes into a steady stream of frames at a fixed broadcast rate.
///
/// - Runs on its own high-priority serial queue, so UI work on the main thread can't
///   delay frames.
/// - Every tick advances the animation by exactly one frame (1/fps seconds), so motion
///   is even, frame to frame, even if a tick fires a little late.
/// - Every tick publishes a frame (re-sending the last one when nothing moves), so the
///   receiver sees a constant rate.
/// - Frames are composited on the GPU (`MetalCompositor`); only a title change touches
///   the CPU (rasterising its pieces once, about 10 ms).
public final class GraphicAnimator {
    public let renderer: GraphicRenderer
    public let compositor: MetalCompositor
    public let queue = DispatchQueue(label: "org.lifenz.lifecg.render", qos: .userInteractive)

    /// Called on the render queue for every frame, before the command buffer is committed:
    /// encode the Syphon publish here.
    public var onFrame: ((MTLTexture, MTLCommandBuffer) -> Void)?
    /// Low-rate preview of the output for the UI, delivered on the main queue.
    public var onPreview: ((CGImage) -> Void)?

    // All of the below is owned by `queue`.
    private var config = Config()
    private var displayed: MetalCompositor.LoadedTitle?
    private var displayedEntry: TitleEntry?
    private var pending: (entry: TitleEntry, title: MetalCompositor.LoadedTitle)?
    private var targetID: String?
    private var progress: Double = 0
    private var direction: Double = 0    // +1 in, -1 out, 0 idle
    private var dirty = true
    private var timer: DispatchSourceTimer?
    private var frameCount = 0
    private var stats = FrameStats()

    public struct Config: Equatable {
        public var inTransition: Transition = .slideBoxFadeText
        public var outTransition: Transition = .slideBoxFadeText
        /// Off-animations play faster than on-animations.
        public var outSpeedFactor: Double = 0.6
        public var frameRate: Double = 50
        public var offset: CGPoint = .zero
        public init() {}
    }

    public init?(renderer: GraphicRenderer) {
        guard let c = MetalCompositor(renderer: renderer) else { return nil }
        self.renderer = renderer
        self.compositor = c
    }

    public func start() { queue.async { self.reschedule() } }

    public func stop() { queue.sync { timer?.cancel(); timer = nil } }

    public func setConfig(_ c: Config) {
        queue.async {
            let rateChanged = c.frameRate != self.config.frameRate
            if c.offset != self.config.offset { self.dirty = true }
            self.config = c
            if rateChanged { self.reschedule() }
        }
    }

    /// Re-rasterise and redraw (after a style change such as fonts).
    public func setStyle(_ style: GraphicStyle) {
        queue.async {
            self.renderer.style = style
            self.config.offset = CGPoint(x: style.offsetX, y: style.offsetY)
            if let e = self.displayedEntry { self.displayed = self.loadEntry(e) }
            if let p = self.pending, let t = self.loadEntry(p.entry) { self.pending = (p.entry, t) }
            self.dirty = true
        }
    }

    /// Measured publish rate over the last couple of seconds (for the UI).
    public func measuredFPS() -> Double { queue.sync { stats.fps } }

    /// Feed the latest store state (any thread).
    public func apply(_ state: TitleState) {
        let target = state.onAir ? state.current : nil
        queue.async { self.applyOnQueue(target) }
    }

    private func applyOnQueue(_ target: TitleEntry?) {
        guard target?.id != targetID else { return }
        targetID = target?.id
        guard let target else {
            pending = nil
            if displayed != nil { direction = -1 }
            return
        }
        if displayed == nil || progress == 0 {
            displayed = loadEntry(target); displayedEntry = target; pending = nil; direction = 1
        } else if displayedEntry?.id == target.id {
            pending = nil; direction = 1                       // reversed mid-out
        } else if let t = loadEntry(target) {
            pending = (target, t); direction = -1              // swap: out, then in
        }
    }

    /// Rasterise a title's pieces with the current style and upload them.
    private func loadEntry(_ e: TitleEntry) -> MetalCompositor.LoadedTitle? {
        compositor.load(renderer.sprites(title: e.title, designation: e.designation))
    }

    private func reschedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / max(config.frameRate, 1)
        t.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        dirty = true
    }

    private func tick() {
        let frame = 1.0 / max(config.frameRate, 1)
        var changed = dirty
        if direction > 0 {
            let d = config.inTransition.duration
            progress = d > 0 ? min(1, progress + frame / d) : 1
            if progress >= 1 { direction = 0 }
            changed = true
        } else if direction < 0 {
            let d = config.outTransition.duration * config.outSpeedFactor * (pending != nil ? 0.7 : 1)
            progress = d > 0 ? max(0, progress - frame / d) : 0
            if progress <= 0 {
                if let p = pending { displayed = p.title; displayedEntry = p.entry; pending = nil; direction = 1 }
                else { displayed = nil; displayedEntry = nil; direction = 0 }
            }
            changed = true
        }
        dirty = false

        guard let cb = compositor.queue.makeCommandBuffer() else { return }
        if changed {
            let plan = displayed.map {
                GraphicRenderer.plan($0.sprites.layout, progress: progress,
                                     transition: direction < 0 ? config.outTransition : config.inTransition)
            }
            compositor.encode(progress > 0 ? displayed : nil, plan: plan, offset: config.offset, into: cb)
        }
        onFrame?(compositor.output, cb)
        // Preview: ~10 fps while moving, and once when it settles.
        frameCount += 1
        if changed && (direction == 0 || frameCount % max(Int(config.frameRate / 10), 1) == 0), let onPreview {
            compositor.encodeReadback(into: cb) { img in
                if let img { DispatchQueue.main.async { onPreview(img) } }
            }
        }
        cb.commit()
        stats.record(CACurrentMediaTime())
    }
}

/// Rolling frames-per-second measurement.
struct FrameStats {
    private var times: [Double] = []
    mutating func record(_ t: Double) {
        times.append(t)
        if times.count > 120 { times.removeFirst(times.count - 120) }
    }
    var fps: Double {
        guard times.count > 10, let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / (last - first)
    }
}
