import CoreGraphics
import Foundation
import Metal

/// Animates the lower third on the GPU at broadcast frame rates.
///
/// Each title's pieces (boxes with shadows, text) are rasterised once on the CPU by
/// `GraphicRenderer.sprites(...)`; every frame is then just a handful of textured quads
/// with alpha, offset and scissor clipping (well under 1 ms) into `output`. The per-frame
/// values come from `GraphicRenderer.plan(...)`, the same maths the CPU renderer uses, so
/// the GPU frames match the CPU reference (see `lt-render --selftest`).
///
/// `output` is a 1920×1080 `.bgra8Unorm` texture, premultiplied alpha, row 0 = top.
/// Not thread-safe: use from one queue.
public final class MetalCompositor {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let output: MTLTexture
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var gradient: MTLTexture?   // theme background layer
    private var plus: MTLTexture?       // theme foreground layer

    /// GPU copy of one title's pieces, plus the finished composite (used for fades,
    /// cuts and the resting frame).
    public final class LoadedTitle {
        public let sprites: GraphicRenderer.SpriteSet
        let titleBox: MTLTexture, titleText: MTLTexture
        let desigBox: MTLTexture?, desigText: MTLTexture?
        var complete: MTLTexture?
        var completeOffset: CGPoint = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        init(sprites: GraphicRenderer.SpriteSet, titleBox: MTLTexture, titleText: MTLTexture,
             desigBox: MTLTexture?, desigText: MTLTexture?) {
            self.sprites = sprites; self.titleBox = titleBox; self.titleText = titleText
            self.desigBox = desigBox; self.desigText = desigText
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Quad { float4 rect; float4 alpha; };   // rect = x, y, w, h in pixels (top-left origin)
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut lt_vs(uint vid [[vertex_id]], constant Quad &q [[buffer(0)]], constant float2 &vp [[buffer(1)]]) {
        float2 c = float2(vid & 1, vid >> 1);
        float2 px = q.rect.xy + c * q.rect.zw;
        VOut o;
        o.pos = float4(px.x / vp.x * 2.0 - 1.0, 1.0 - px.y / vp.y * 2.0, 0.0, 1.0);
        o.uv = c;
        return o;
    }
    fragment float4 lt_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                          constant Quad &q [[buffer(0)]]) {
        return tex.sample(s, in.uv) * q.alpha.x;   // premultiplied: scale all channels
    }
    """

    private struct Quad {
        var rect: SIMD4<Float>
        var alpha: SIMD4<Float>
    }

    public init?(renderer: GraphicRenderer, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "lt_vs")
            d.fragmentFunction = lib.makeFunction(name: "lt_fs")
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("LifeCG: Metal compositor setup failed: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToZero; sd.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: sd),
              let out = Self.makeTarget(device) else { return nil }
        self.sampler = sampler
        output = out
        loadLayers(from: renderer)
    }

    /// (Re)upload the theme's background/foreground layers (call after a theme change).
    public func loadLayers(from renderer: GraphicRenderer) {
        gradient = renderer.backgroundLayer.flatMap { Self.texture(device, $0) }
        plus = renderer.foregroundLayer.flatMap { Self.texture(device, $0) }
    }

    private static func makeTarget(_ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: GraphicRenderer.width,
                                                         height: GraphicRenderer.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// Upload a premultiplied CGImage (redrawn into BGRA so the byte layout is guaranteed).
    static func texture(_ device: MTLDevice, _ img: CGImage) -> MTLTexture? {
        let ctx = GraphicRenderer.makeContext(width: img.width, height: img.height)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: img.width,
                                                         height: img.height, mipmapped: false)
        d.usage = [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0,
                  withBytes: ctx.data!, bytesPerRow: ctx.bytesPerRow)
        return t
    }

    public func load(_ s: GraphicRenderer.SpriteSet) -> LoadedTitle? {
        guard let tb = Self.texture(device, s.titleBox.image), let tt = Self.texture(device, s.titleText.image) else { return nil }
        return LoadedTitle(sprites: s, titleBox: tb, titleText: tt,
                           desigBox: s.desigBox.flatMap { Self.texture(device, $0.image) },
                           desigText: s.desigText.flatMap { Self.texture(device, $0.image) })
    }

    /// Encode one frame into `output`. `title == nil` or `plan == nil` → transparent frame.
    public func encode(_ title: LoadedTitle?, plan: FramePlan?, offset: CGPoint, into cb: MTLCommandBuffer) {
        guard let title, let plan else { clear(cb, output); return }
        if plan.isComplete || plan.globalAlpha < 1 {
            // Finished graphic, a cut, or a fade (which fades the composite as one).
            let full = completeTexture(title, offset: offset, cb: cb)
            pass(cb, output) { enc in
                self.draw(enc, full, rect: CGRect(x: 0, y: 0, width: GraphicRenderer.width, height: GraphicRenderer.height),
                          alpha: plan.isComplete ? 1 : plan.globalAlpha, offset: .zero, clip: nil)
            }
            return
        }
        pass(cb, output) { enc in self.drawPlan(enc, title, plan, offset: offset) }
    }

    private func completeTexture(_ t: LoadedTitle, offset: CGPoint, cb: MTLCommandBuffer) -> MTLTexture {
        if let c = t.complete, t.completeOffset == offset { return c }
        let c = t.complete ?? Self.makeTarget(device)!
        let plan = GraphicRenderer.plan(t.sprites.layout, progress: 1, transition: .slideBoxFadeText)
        pass(cb, c) { enc in self.drawPlan(enc, t, plan, offset: offset) }
        t.complete = c
        t.completeOffset = offset
        return c
    }

    private func drawPlan(_ enc: MTLRenderCommandEncoder, _ t: LoadedTitle, _ plan: FramePlan, offset: CGPoint) {
        let full = CGRect(x: 0, y: 0, width: GraphicRenderer.width, height: GraphicRenderer.height)
        if let gradient, plan.gradientAlpha > 0 {
            draw(enc, gradient, rect: full, alpha: plan.gradientAlpha, offset: offset, clip: nil)
        }
        let s = t.sprites
        if plan.title.visible {
            draw(enc, t.titleBox, rect: s.titleBox.rect.offsetBy(dx: plan.title.dx, dy: 0), alpha: 1, offset: offset, clip: plan.title.clip)
            if plan.title.textAlpha > 0 {
                draw(enc, t.titleText, rect: s.titleText.rect.offsetBy(dx: plan.title.dx, dy: 0),
                     alpha: plan.title.textAlpha, offset: offset, clip: plan.title.clip)
            }
        }
        if plan.desig.visible, let db = t.desigBox, let dbs = s.desigBox {
            draw(enc, db, rect: dbs.rect.offsetBy(dx: plan.desig.dx, dy: 0), alpha: 1, offset: offset, clip: plan.desig.clip)
            if plan.desig.textAlpha > 0, let dt = t.desigText, let dts = s.desigText {
                draw(enc, dt, rect: dts.rect.offsetBy(dx: plan.desig.dx, dy: 0),
                     alpha: plan.desig.textAlpha, offset: offset, clip: plan.desig.clip)
            }
        }
        if let plus, plan.plusAlpha > 0 {
            draw(enc, plus, rect: full.offsetBy(dx: plan.plusShift, dy: 0), alpha: plan.plusAlpha, offset: offset, clip: nil)
        }
    }

    /// Draw `tex` covering `rect` (CG coords, y up) with the style offset (+x right, +y down).
    private func draw(_ enc: MTLRenderCommandEncoder, _ tex: MTLTexture, rect: CGRect, alpha: Double,
                      offset: CGPoint, clip: CGRect?) {
        let H = CGFloat(GraphicRenderer.height), W = CGFloat(GraphicRenderer.width)
        func toTop(_ r: CGRect) -> CGRect {   // CG (bottom-left) → texture (top-left), plus offset
            CGRect(x: r.minX + offset.x, y: H - r.maxY + offset.y, width: r.width, height: r.height)
        }
        if let clip {
            let c = toTop(clip).intersection(CGRect(x: 0, y: 0, width: W, height: H))
            if c.isNull || c.width < 0.5 || c.height < 0.5 { return }
            let x0 = Int(c.minX.rounded()), y0 = Int(c.minY.rounded())
            let x1 = Int(c.maxX.rounded()), y1 = Int(c.maxY.rounded())
            guard x1 > x0, y1 > y0 else { return }
            enc.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        } else {
            enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(W), height: Int(H)))
        }
        let r = toTop(rect)
        var q = Quad(rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
                     alpha: SIMD4(Float(alpha), 0, 0, 0))
        var vp = SIMD2<Float>(Float(W), Float(H))
        enc.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
        enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setFragmentBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func pass(_ cb: MTLCommandBuffer, _ target: MTLTexture, _ body: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        body(enc)
        enc.endEncoding()
    }

    private func clear(_ cb: MTLCommandBuffer, _ target: MTLTexture) { pass(cb, target) { _ in } }

    // MARK: - Preview (half size, reused buffers)

    public static let previewWidth = GraphicRenderer.width / 2
    public static let previewHeight = GraphicRenderer.height / 2
    private lazy var previewTarget: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.previewWidth,
                                                         height: Self.previewHeight, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }()
    /// Two buffers alternate so a preview being read on the CPU is never overwritten.
    private lazy var previewBuffers: [MTLBuffer] = (0..<2).compactMap { _ in
        device.makeBuffer(length: Self.previewWidth * 4 * Self.previewHeight, options: .storageModeShared)
    }
    private var previewIndex = 0

    /// Downscale `output` on the GPU and copy it into a reused buffer; `completion` gets a
    /// half-size image on a Metal thread. About 2 MB per preview instead of 8 MB, no allocation.
    public func encodePreview(into cb: MTLCommandBuffer, completion: @escaping (CGImage?) -> Void) {
        guard let target = previewTarget, previewBuffers.count == 2 else { completion(nil); return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { completion(nil); return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        var q = Quad(rect: SIMD4(0, 0, Float(GraphicRenderer.width), Float(GraphicRenderer.height)), alpha: SIMD4(1, 0, 0, 0))
        var vp = SIMD2<Float>(Float(GraphicRenderer.width), Float(GraphicRenderer.height))
        enc.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
        enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setFragmentBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
        enc.setFragmentTexture(output, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        let buf = previewBuffers[previewIndex]
        previewIndex ^= 1
        let w = Self.previewWidth, h = Self.previewHeight, bpr = w * 4
        guard let blit = cb.makeBlitCommandEncoder() else { completion(nil); return }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            completion(Self.image(from: buf, width: w, height: h))
        }
    }

    // MARK: - Read back (tests, stills)

    /// Copy `output` into a CPU image after `cb` completes; `completion` runs on a Metal thread.
    public func encodeReadback(into cb: MTLCommandBuffer, completion: @escaping (CGImage?) -> Void) {
        guard let buf = encodeCopy(into: cb) else { completion(nil); return }
        cb.addCompletedHandler { _ in completion(Self.image(from: buf)) }
    }

    private func encodeCopy(into cb: MTLCommandBuffer) -> MTLBuffer? {
        let bpr = GraphicRenderer.width * 4
        guard let buf = device.makeBuffer(length: bpr * GraphicRenderer.height, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: GraphicRenderer.width, height: GraphicRenderer.height, depth: 1),
                  to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * GraphicRenderer.height)
        blit.endEncoding()
        return buf
    }

    private static func image(from buf: MTLBuffer, width: Int = GraphicRenderer.width,
                              height: Int = GraphicRenderer.height) -> CGImage? {
        let bpr = width * 4
        let data = Data(bytes: buf.contents(), count: bpr * height)   // copy: the buffer gets reused
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGDataProvider(data: data as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: bpr, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// Synchronous single frame → image (tests and CLI).
    public func renderImage(_ title: LoadedTitle?, plan: FramePlan?, offset: CGPoint = .zero) -> CGImage? {
        guard let cb = queue.makeCommandBuffer() else { return nil }
        encode(title, plan: plan, offset: offset, into: cb)
        guard let buf = encodeCopy(into: cb) else { return nil }
        cb.commit()
        cb.waitUntilCompleted()
        return Self.image(from: buf)
    }
}
