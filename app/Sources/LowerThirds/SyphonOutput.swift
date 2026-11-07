import Foundation
import Metal
#if canImport(LowerThirdsCore)
import LowerThirdsCore
#endif
import Syphon

/// Publishes rendered frames as a Syphon server (1920×1080 BGRA, premultiplied alpha).
final class SyphonOutput {
    private(set) var name: String
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var texture: MTLTexture
    private var server: SyphonMetalServer?

    init?(name: String) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: GraphicRenderer.width, height: GraphicRenderer.height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        texture = tex
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
        guard newName != name else { return }
        server?.stop()
        name = newName
        server = Self.makeServer(name: newName, device: device)
    }

    var clientCount: Int { (server?.hasClients ?? false) ? 1 : 0 }
    var hasClients: Bool { server?.hasClients ?? false }

    func publish(_ r: GraphicRenderer) {
        guard let server else { return }
        let region = MTLRegionMake2D(0, 0, GraphicRenderer.width, GraphicRenderer.height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: r.bytes, bytesPerRow: r.bytesPerRow)
        guard let cb = queue.makeCommandBuffer() else { return }
        // The CGContext buffer is top-row-first, which is Metal's texture orientation → not flipped.
        server.publishFrameTexture(texture, on: cb,
                                   imageRegion: NSRect(x: 0, y: 0, width: GraphicRenderer.width, height: GraphicRenderer.height),
                                   flipped: SyphonOutput.flipped)
        cb.commit()
    }

    /// Orientation flag for publishFrameTexture; verified by the Syphon smoke test.
    static var flipped = false

    func stop() {
        server?.stop()
        server = nil
    }
}
