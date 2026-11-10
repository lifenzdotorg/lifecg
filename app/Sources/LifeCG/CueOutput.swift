import CoreGraphics
import Foundation
import Metal
#if canImport(LifeCGCore)
import LifeCGCore
#endif

/// The speaker's cue (confidence) screen as a second Syphon server: plain text, current and next
/// notes slide, opaque black. Nothing moves, so it publishes the last frame at a low fixed rate.
final class CueOutput {
    private let syphon: SyphonOutput
    private let compositor: MetalCompositor
    private let queue = DispatchQueue(label: "org.lifenz.lifecg.cue", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var texture: MTLTexture?   // owned by `queue`
    private(set) var frameRate: Double

    init?(name: String, compositor: MetalCompositor, frameRate: Double) {
        guard let s = SyphonOutput(name: name, device: compositor.device) else { return nil }
        syphon = s
        self.compositor = compositor
        self.frameRate = frameRate
        start()
    }

    var name: String { syphon.name }
    var hasClients: Bool { syphon.hasClients }
    func rename(_ n: String) { syphon.rename(n) }

    /// Render new content (main thread) and swap it in.
    func show(_ content: CueRenderer.Content) {
        guard let img = CueRenderer.render(content), let tex = compositor.makeTexture(img) else { return }
        queue.async { self.texture = tex }
    }

    func setFrameRate(_ fps: Double) {
        queue.async { self.frameRate = fps; self.start() }
    }

    private func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / max(frameRate, 1), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let tex = texture, let cb = compositor.queue.makeCommandBuffer() else { return }
        syphon.publish(tex, on: cb)
        cb.commit()
    }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
        syphon.stop()
    }
}
