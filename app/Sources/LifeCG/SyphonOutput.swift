import Foundation
import Metal
#if canImport(LifeCGCore)
import LifeCGCore
#endif
import Syphon

/// Publishes the compositor's output texture as a Syphon server
/// (1920×1080 BGRA, premultiplied alpha). Called on the render queue.
final class SyphonOutput {
    private(set) var name: String
    private let device: MTLDevice
    private var server: SyphonMetalServer?
    private let lock = NSLock()

    init?(name: String, device: MTLDevice) {
        self.device = device
        self.name = name
        server = Self.makeServer(name: name, device: device)
        if server == nil { return nil }
    }

    /// The ObjC init can return nil (e.g. runtime shader compile failure) even though
    /// Swift imports it as non-optional, so check the raw pointer.
    private static func makeServer(name: String, device: MTLDevice) -> SyphonMetalServer? {
        let s = SyphonMetalServer(name: name, device: device, options: nil)
        return unsafeBitCast(s, to: Int.self) == 0 ? nil : s
    }

    /// Rename by recreating the server (clients see a new source name).
    func rename(_ newName: String) {
        lock.lock(); defer { lock.unlock() }
        guard newName != name else { return }
        server?.stop()
        name = newName
        server = Self.makeServer(name: newName, device: device)
    }

    var hasClients: Bool { lock.lock(); defer { lock.unlock() }; return server?.hasClients ?? false }

    /// Encode a publish of `texture` (row 0 = top) into `cb`; the caller commits.
    func publish(_ texture: MTLTexture, on cb: MTLCommandBuffer) {
        lock.lock(); defer { lock.unlock() }
        // Syphon frames are bottom-left origin (OpenGL convention): receivers such as
        // ProPresenter read the IOSurface's first row as the BOTTOM of the picture.
        // Our texture is top-row-first, so it must be published flipped.
        server?.publishFrameTexture(texture, on: cb,
                                    imageRegion: NSRect(x: 0, y: 0, width: GraphicRenderer.width, height: GraphicRenderer.height),
                                    flipped: SyphonOutput.flipped)
    }

    /// Must be true for a top-row-first source: with false, ProPresenter showed the
    /// graphic upside down (confirmed in PP7, Nov 2026).
    static let flipped = true

    func stop() {
        lock.lock(); defer { lock.unlock() }
        server?.stop()
        server = nil
    }
}
