// syphon-grab: connect to a running Syphon server and save one frame as PNG.
// Independent check that LifeCG.app is publishing what we expect.
//   syphon-grab <server name> <out.png>
import Foundation
import Metal
import IOSurface
import CoreGraphics
import ImageIO
import Syphon

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: syphon-grab <server name> <out.png>"); exit(2) }
func pump(_ s: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }
let device = MTLCreateSystemDefaultDevice()!
let dir = SyphonServerDirectory.shared()
var desc: [String: Any]?
let deadline = Date(timeIntervalSinceNow: 10)
while desc == nil && Date() < deadline {
    desc = dir.servers(matchingName: args[1], appName: nil).first.map { $0 as [String: Any] }
    if desc == nil { pump(0.1) }
}
guard let desc else { print("server '\(args[1])' not found. Available: \(dir.servers.map { ($0 as NSDictionary)[SyphonServerDescriptionNameKey] ?? "?" })"); exit(1) }
print("found: \(desc[SyphonServerDescriptionNameKey] ?? "") from \(desc[SyphonServerDescriptionAppNameKey] ?? "")")
let client = SyphonMetalClient(serverDescription: desc, device: device, options: nil, newFrameHandler: nil)
var frame: MTLTexture?
let d2 = Date(timeIntervalSinceNow: 5)
while frame == nil && Date() < d2 { pump(0.1); if client.hasNewFrame || true { frame = client.newFrameImage() } }
guard let frame, let surf = frame.iosurface else { print("no frame"); exit(1) }
let s = unsafeBitCast(surf, to: IOSurface.self)
s.lock(options: .readOnly, seed: nil)
let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
let ctx = CGContext(data: s.baseAddress, width: s.width, height: s.height, bitsPerComponent: 8, bytesPerRow: s.bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
// Syphon surfaces are bottom-left origin (OpenGL convention): the first row in memory is
// the BOTTOM of the picture. Real receivers (ProPresenter, Resolume, Syphon Simple Client)
// read it that way, so flip here too or this tool will disagree with them.
let raw = ctx.makeImage()!
s.unlock(options: .readOnly, seed: nil)
let out = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
out.translateBy(x: 0, y: CGFloat(raw.height)); out.scaleBy(x: 1, y: -1)
out.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
let img = out.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
print("saved \(frame.width)x\(frame.height) to \(args[2])")
client.stop()
