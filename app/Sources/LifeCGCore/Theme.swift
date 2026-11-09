import CoreGraphics
import Foundation
import ImageIO

/// A speaker-title look: where the bars sit, their colours, fonts and decoration layers.
///
/// A theme is a folder containing `theme.json` plus optional full-frame (1920×1080) PNG layers:
/// `background` is drawn under the bars (e.g. a soft gradient) and `foreground` over them
/// (e.g. ornaments). Bars resize to fit the text and stay pinned to the `anchor` side, so
/// anything fixed in position belongs in a layer and anything that follows the text is drawn
/// by the renderer.
///
/// Built-in themes ship inside the app (`Contents/Resources/Themes`); imported themes live in
/// `~/Library/Application Support/LifeCG/Themes/<id>/` and can be edited by hand.
public struct Theme: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var id: String
    public var name: String
    /// Which side the bars are pinned to; they grow away from it.
    public var anchor: Anchor = .right
    /// File names (inside the theme folder) of the full-frame layers.
    public var backgroundLayer: String?
    public var foregroundLayer: String?
    public var title: Bar
    /// nil: the theme has no designation bar.
    public var designation: Bar?
    /// Bars never extend closer than this to the far screen edge; long text shrinks instead.
    public var edgeMargin: Double = 40
    /// Where the theme came from (e.g. "Imported from sample.png"), for the UI.
    public var notes: String?

    public enum Anchor: String, Codable, Sendable { case left, right }

    public struct Bar: Codable, Equatable, Sendable {
        /// x of the edge on the anchor side (pixels from the left of a 1920-wide frame).
        public var anchorX: Double
        public var top: Double
        public var bottom: Double
        /// Padding between text ink and the anchored edge, and the free edge.
        public var padOuter: Double
        public var padInner: Double
        /// Text baseline, pixels from the top.
        public var baseline: Double
        public var color: String          // "#RRGGBBAA"
        public var textColor: String
        /// PostScript names, tried in order (falls back to the system font).
        public var fonts: [String]
        /// Text is sized by cap height so fallback fonts keep the same visual size.
        public var capHeight: Double
        /// Letter spacing in em.
        public var tracking: Double
        public var uppercase: Bool = false
        public var shadow: Shadow?

        public init(anchorX: Double, top: Double, bottom: Double, padOuter: Double, padInner: Double, baseline: Double,
                    color: String, textColor: String, fonts: [String], capHeight: Double, tracking: Double,
                    uppercase: Bool = false, shadow: Shadow? = nil) {
            self.anchorX = anchorX; self.top = top; self.bottom = bottom
            self.padOuter = padOuter; self.padInner = padInner; self.baseline = baseline
            self.color = color; self.textColor = textColor; self.fonts = fonts
            self.capHeight = capHeight; self.tracking = tracking; self.uppercase = uppercase; self.shadow = shadow
        }
    }

    public struct Shadow: Codable, Equatable, Sendable {
        public var offsetY: Double = 4
        public var blur: Double = 18
        public var opacity: Double = 0.22
        public init(offsetY: Double = 4, blur: Double = 18, opacity: Double = 0.22) {
            self.offsetY = offsetY; self.blur = blur; self.opacity = opacity
        }
    }

    public init(id: String, name: String, anchor: Anchor = .right, backgroundLayer: String? = nil,
                foregroundLayer: String? = nil, title: Bar, designation: Bar?, notes: String? = nil) {
        self.id = id; self.name = name; self.anchor = anchor
        self.backgroundLayer = backgroundLayer; self.foregroundLayer = foregroundLayer
        self.title = title; self.designation = designation; self.notes = notes
    }

    /// The original LIFE NodeCG look (measured from docs/reference-composite.png). Used when
    /// the built-in theme folder can't be found, so the app always has something to draw.
    public static let life = Theme(
        id: "life", name: "LIFE", anchor: .right,
        backgroundLayer: "background.png", foregroundLayer: "foreground.png",
        title: Bar(anchorX: 1795, top: 918, bottom: 993, padOuter: 26, padInner: 23, baseline: 972.5,
                   color: "#FDFDFDE8", textColor: "#222222FF",
                   fonts: ["NeuzeitGro-Bol", "NeuzeitGrotesk-Bold", "AvenirNext-Bold", "HelveticaNeue-Bold"],
                   capHeight: 39.5, tracking: 0.0675, shadow: Shadow()),
        designation: Bar(anchorX: 1806, top: 993, bottom: 1047, padOuter: 53, padInner: 30, baseline: 1030.5,
                         color: "#242424ED", textColor: "#FFFFFFFF",
                         fonts: ["NeuzeitGro-Reg", "NeuzeitGrotesk-Regular", "AvenirNext-Regular", "HelveticaNeue"],
                         capHeight: 23.5, tracking: 0.0923, shadow: Shadow()),
        notes: "Built in: the original LIFE NodeCG graphic")
}

/// A theme plus its folder and decoded layers, ready to render.
public struct LoadedTheme {
    public let theme: Theme
    public let folder: URL?
    public let isBuiltIn: Bool
    public let background: CGImage?
    public let foreground: CGImage?

    public init(theme: Theme, folder: URL?, isBuiltIn: Bool) {
        self.theme = theme
        self.folder = folder
        self.isBuiltIn = isBuiltIn
        func layer(_ name: String?) -> CGImage? {
            guard let name, let folder else { return nil }
            return loadPNG(folder.appendingPathComponent(name))
        }
        background = layer(theme.backgroundLayer)
        foreground = layer(theme.foregroundLayer)
    }

    /// An in-memory theme (e.g. a PNG import being previewed before it's saved).
    public init(theme: Theme, background: CGImage?, foreground: CGImage?) {
        self.theme = theme
        self.folder = nil
        self.isBuiltIn = false
        self.background = background
        self.foreground = foreground
    }

    /// The built-in LIFE theme from the app bundle (or source tree), or its code fallback.
    public static var builtInLife: LoadedTheme {
        ThemeLibrary.builtInFolders().first { $0.lastPathComponent == "life" }
            .flatMap { ThemeLibrary.load(folder: $0, builtIn: true) }
            ?? LoadedTheme(theme: .life, folder: nil, isBuiltIn: true)
    }
}

/// Built-in + imported themes on disk.
public enum ThemeLibrary {
    public static var userFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LifeCG/Themes", isDirectory: true)
    }

    static func builtInFolders() -> [URL] {
        guard let root = Resources.directory("Themes") else { return [] }
        return subfolders(root)
    }

    static func subfolders(_ root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("theme.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func load(folder: URL, builtIn: Bool) -> LoadedTheme? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("theme.json")),
              let theme = try? JSONDecoder().decode(Theme.self, from: data) else { return nil }
        return LoadedTheme(theme: theme, folder: folder, isBuiltIn: builtIn)
    }

    /// Every theme: built-in first, then imported. An imported theme with a built-in id is skipped.
    public static func all() -> [LoadedTheme] {
        var out = builtInFolders().compactMap { load(folder: $0, builtIn: true) }
        if out.isEmpty { out = [LoadedTheme(theme: .life, folder: nil, isBuiltIn: true)] }
        let builtInIDs = Set(out.map(\.theme.id))
        out += subfolders(userFolder).compactMap { load(folder: $0, builtIn: false) }.filter { !builtInIDs.contains($0.theme.id) }
        return out
    }

    /// Write a theme (and its layer images) into the user folder; returns its folder.
    @discardableResult
    public static func save(_ theme: Theme, background: CGImage?, foreground: CGImage?, extras: [String: CGImage] = [:]) throws -> URL {
        let folder = userFolder.appendingPathComponent(theme.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var t = theme
        t.backgroundLayer = background == nil ? nil : "background.png"
        t.foregroundLayer = foreground == nil ? nil : "foreground.png"
        if let background { try writePNG(background, folder.appendingPathComponent("background.png")) }
        if let foreground { try writePNG(foreground, folder.appendingPathComponent("foreground.png")) }
        for (name, img) in extras { try writePNG(img, folder.appendingPathComponent(name)) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(t).write(to: folder.appendingPathComponent("theme.json"), options: .atomic)
        return folder
    }

    public static func delete(id: String) throws {
        let folder = userFolder.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// A folder-safe id from a display name, unique among existing themes.
    public static func makeID(for name: String) -> String {
        let base = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let stem = base.isEmpty ? "theme" : base
        let existing = Set(all().map(\.theme.id))
        var id = stem, n = 2
        while existing.contains(id) { id = "\(stem)-\(n)"; n += 1 }
        return id
    }
}

// MARK: - Colour and image helpers

extension CGColor {
    /// "#RRGGBB" or "#RRGGBBAA" (sRGB). Invalid strings give opaque magenta, so mistakes are obvious.
    public static func hex(_ s: String) -> CGColor {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 6 { h += "FF" }
        guard h.count == 8, let v = UInt32(h, radix: 16) else { return CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) }
        return CGColor(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                       blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }
}

public func hexString(r: Double, g: Double, b: Double, a: Double) -> String {
    func c(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
    return "#" + c(r) + c(g) + c(b) + c(a)
}

public func loadPNG(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

public func writePNG(_ img: CGImage, _ url: URL) throws {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { throw CocoaError(.fileWriteUnknown) }
}
