import Foundation

/// Finds bundled resources whether we run from the .app bundle, from a bare
/// build directory, or straight from the source tree (dev / CLI).
enum Resources {
    static func url(_ name: String, ext: String) -> URL? {
        candidates("\(name).\(ext)").first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A bundled folder, e.g. "Themes".
    static func directory(_ name: String) -> URL? {
        var isDir: ObjCBool = false
        return candidates(name).first { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
    }

    private static func candidates(_ item: String) -> [URL] {
        var out: [URL] = []
        if let r = Bundle.main.resourceURL { out.append(r.appendingPathComponent(item)) }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        out.append(exeDir.appendingPathComponent(item))
        out.append(exeDir.appendingPathComponent("Resources").appendingPathComponent(item))
        // Source tree: app/Sources/LifeCGCore/Resources.swift → app/<item>
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        out.append(appDir.appendingPathComponent(item))
        return out
    }
}
