import Foundation
import QuartzCore

/// Turns on-air state changes into rendered frames.
/// Renders at 60 fps while animating; when static it re-emits the last frame
/// every `keepAliveInterval` so Syphon clients that join late still get a picture.
public final class GraphicAnimator {
    /// How the title animates on and off; chosen independently.
    public var inTransition: Transition = .slideBoxFadeText
    public var outTransition: Transition = .slideBoxFadeText
    /// Off-animations play faster than on-animations.
    public var outSpeedFactor: Double = 0.6
    public var keepAliveInterval: Double = 0.5

    /// Called on the main queue after each frame is rendered into `renderer`.
    public var onFrame: ((GraphicRenderer) -> Void)?

    public let renderer: GraphicRenderer
    private var displayed: TitleEntry?   // what is drawn right now
    private var pending: TitleEntry?     // what should be drawn after an out-animation
    private var target: TitleEntry?      // desired on-air entry (nil = off)
    private var progress: Double = 0
    private var direction: Double = 0    // +1 in, -1 out, 0 idle
    private var lastTick = CACurrentMediaTime()
    private var lastEmit = 0.0
    private var timer: DispatchSourceTimer?

    public init(renderer: GraphicRenderer) {
        self.renderer = renderer
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        draw()
    }

    public func stop() { timer?.cancel(); timer = nil }

    /// Re-render now (e.g. after a style change).
    public func redraw() { draw() }

    public var isAnimating: Bool { direction != 0 }

    /// Feed the latest store state.
    public func apply(_ state: TitleState) {
        let newTarget = state.onAir ? state.current : nil
        guard newTarget != target || (newTarget != nil && displayed?.id != newTarget?.id) else { return }
        target = newTarget
        if let newTarget {
            if displayed == nil || progress == 0 {
                displayed = newTarget; pending = nil; direction = 1
            } else if displayed?.id == newTarget.id {
                pending = nil; direction = 1          // e.g. reversed mid-out
            } else {
                pending = newTarget; direction = -1   // swap: out, then in
            }
        } else {
            pending = nil
            if displayed != nil { direction = -1 }
        }
        lastTick = CACurrentMediaTime()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        if direction > 0 {
            let d = inTransition.duration
            progress = d > 0 ? min(1, progress + dt / d) : 1
            if progress >= 1 { direction = 0 }
            draw()
        } else if direction < 0 {
            // Swapping titles: go out faster still.
            let d = outTransition.duration * outSpeedFactor * (pending != nil ? 0.7 : 1)
            progress = d > 0 ? max(0, progress - dt / d) : 0
            if progress <= 0 {
                if let p = pending { displayed = p; pending = nil; direction = 1 }
                else { displayed = nil; direction = 0 }
            }
            draw()
        } else if now - lastEmit >= keepAliveInterval {
            lastEmit = now
            onFrame?(renderer)
        }
    }

    private func draw() {
        renderer.render(title: displayed?.title, designation: displayed?.designation ?? "", progress: progress,
                        transition: direction < 0 ? outTransition : inTransition)
        lastEmit = CACurrentMediaTime()
        onFrame?(renderer)
    }
}
