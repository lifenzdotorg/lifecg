import Foundation

/// Finds bundled resources whether we run from the .app bundle, from a bare
/// build directory, or straight from the source tree (dev / CLI).
enum Resources {
    static func url(_ name: String, ext: String) -> URL? {
        let file = "\(name).\(ext)"
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(file)) }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent(file))
        candidates.append(exeDir.appendingPathComponent("Resources").appendingPathComponent(file))
        // Source tree: Sources/LifeCGCore/Resources/<file>
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(file))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
