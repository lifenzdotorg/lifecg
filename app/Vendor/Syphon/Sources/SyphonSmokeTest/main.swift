// SyphonSmokeTest: publishes a known 1920x1080 premultiplied-alpha BGRA pattern via SyphonMetalServer,
// discovers it in-process via SyphonServerDirectory, reads it back with SyphonMetalClient and verifies
// every pixel (including alpha). Exercises three server paths:
//   1. blit path         (.bgra8Unorm source, flipped: false)  - what the app will normally hit
//   2. shader path + flip (.bgra8Unorm source, flipped: true)  - uses the runtime-compiled shaders
//   3. shader path        (.rgba8Unorm source, flipped: false) - runtime shaders, format conversion
import Foundation
import CoreGraphics
import Metal
import IOSurface
import Syphon

let width = 1920
let height = 1080
let serverName = "SmokeTest"

func fail(_ msg: String) -> Never {
    print("FAIL: \(msg)")
    exit(1)
}

/// Pump the main run loop (distributed notifications used by SyphonServerDirectory are delivered here).
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

/// Expected premultiplied pixel at (x, y) in top-left-origin image space, as (b, g, r, a).
func expected(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let alphas: [Int] = [255, 191, 128, 64, 1, 0]
    let a = alphas[((x / 37) + (y / 23)) % alphas.count]
    let r = (x * 255) / (width - 1)
    let g = (y * 255) / (height - 1)
    let b = (x ^ y) & 0xFF
    // premultiply
    return (UInt8(b * a / 255), UInt8(g * a / 255), UInt8(r * a / 255), UInt8(a))
}

func makeTexture(device: MTLDevice, format: MTLPixelFormat) -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    desc.usage = [.shaderRead, .renderTarget]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { fail("could not create texture") }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (b, g, r, a) = expected(x, y)
            let i = (y * width + x) * 4
            if format == .rgba8Unorm {
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
            } else {
                bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r; bytes[i + 3] = a
            }
        }
    }
    bytes.withUnsafeBytes { raw in
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: raw.baseAddress!, bytesPerRow: width * 4)
    }
    return tex
}

/// Compare the client's IOSurface (BGRA, row 0 = top) with the expected pattern.
func verify(surface: IOSurface, flippedSource: Bool, label: String) -> Bool {
    guard surface.width == width, surface.height == height else {
        print("  [\(label)] wrong size \(surface.width)x\(surface.height)")
        return false
    }
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }
    let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
    let bpr = surface.bytesPerRow
    var mismatches = 0
    var maxDiff = 0
    var firstBad = ""
    var alphaSeen = Set<UInt8>()
    for y in 0..<height {
        // flipped: true means "the source is upside down", so Syphon flips it: output row y = source row H-1-y
        let srcY = flippedSource ? (height - 1 - y) : y
        for x in 0..<width {
            let e = expected(x, srcY)
            let p = base + y * bpr + x * 4
            let got = (p[0], p[1], p[2], p[3])
            alphaSeen.insert(got.3)
            let d = max(abs(Int(got.0) - Int(e.0)), abs(Int(got.1) - Int(e.1)),
                        abs(Int(got.2) - Int(e.2)), abs(Int(got.3) - Int(e.3)))
            maxDiff = max(maxDiff, d)
            if d > 0 {
                mismatches += 1
                if firstBad.isEmpty { firstBad = "(\(x),\(y)) got BGRA\(got) expected \(e)" }
            }
        }
    }
    let ok = maxDiff == 0
    print("  [\(label)] \(ok ? "ok" : "MISMATCH"): \(width * height - mismatches)/\(width * height) pixels exact, max channel diff \(maxDiff), distinct alpha values \(alphaSeen.sorted())\(firstBad.isEmpty ? "" : ", first mismatch \(firstBad)")")
    return ok
}

// MARK: - Run

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fail("no Metal device")
}
print("Metal device: \(device.name)")

let server = SyphonMetalServer(name: serverName, device: device, options: nil)
// The ObjC init can return nil (e.g. if the shader library fails to compile) even though Swift imports it as non-optional.
// Check the raw pointer rather than comparing with nil, which the optimizer may assume is impossible.
if unsafeBitCast(server, to: Int.self) == 0 { fail("SyphonMetalServer init returned nil") }
print("Server created: uuid=\(server.serverDescription[SyphonServerDescriptionUUIDKey].map { "\($0)" } ?? "?")")

let bgra = makeTexture(device: device, format: .bgra8Unorm)
let rgba = makeTexture(device: device, format: .rgba8Unorm)

func publish(_ tex: MTLTexture, flipped: Bool) {
    guard let cb = queue.makeCommandBuffer() else { fail("no command buffer") }
    server.publishFrameTexture(tex, on: cb, imageRegion: CGRect(x: 0, y: 0, width: width, height: height), flipped: flipped)
    cb.commit()
    cb.waitUntilCompleted()
    if let err = cb.error { fail("command buffer error: \(err)") }
}

// Publish a couple of frames, pumping the run loop so announcements go out.
for _ in 0..<3 { publish(bgra, flipped: false); pump(0.05) }

// Discover the server via SyphonServerDirectory.
let directory = SyphonServerDirectory.shared()
var description: [String: Any]? = nil
let discoverDeadline = Date(timeIntervalSinceNow: 10)
while description == nil && Date() < discoverDeadline {
    let matches = directory.servers(matchingName: serverName, appName: nil)
    if let first = matches.first { description = first as [String: Any] }
    if description == nil { pump(0.1) }
}
guard let description else { fail("server '\(serverName)' not discovered via SyphonServerDirectory within 10 s") }
print("Discovered: name=\(description[SyphonServerDescriptionNameKey] ?? "?") app=\(description[SyphonServerDescriptionAppNameKey] ?? "?")")

let client = SyphonMetalClient(serverDescription: description, device: device, options: nil, newFrameHandler: nil)
if unsafeBitCast(client, to: Int.self) == 0 || !client.isValid { fail("SyphonMetalClient invalid") }

func roundTrip(_ tex: MTLTexture, flipped: Bool, label: String) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    // Drain any stale frame flag, then publish until the client reports a new frame.
    _ = client.newFrameImage()
    while Date() < deadline {
        publish(tex, flipped: flipped)
        pump(0.05)
        if client.hasNewFrame { break }
    }
    guard let frame = client.newFrameImage() else {
        print("  [\(label)] client returned no frame"); return false
    }
    guard let surface = frame.iosurface else {
        print("  [\(label)] client texture has no IOSurface"); return false
    }
    print("  [\(label)] client texture \(frame.width)x\(frame.height) format \(frame.pixelFormat.rawValue) (bgra8Unorm=\(MTLPixelFormat.bgra8Unorm.rawValue))")
    return verify(surface: unsafeBitCast(surface, to: IOSurface.self), flippedSource: flipped, label: label)
}

var allOK = true
allOK = roundTrip(bgra, flipped: false, label: "blit bgra8 flipped:false") && allOK
allOK = roundTrip(bgra, flipped: true, label: "shader bgra8 flipped:true") && allOK
allOK = roundTrip(rgba, flipped: false, label: "shader rgba8 flipped:false") && allOK

client.stop()
server.stop()
print(allOK ? "PASS" : "FAIL")
exit(allOK ? 0 : 1)
