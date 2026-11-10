import CoreGraphics
import Foundation
import ImageIO

// Speaker notes: the audience-facing scripture / point lower thirds.
// Formats are defined in docs/notes-platform/FORMAT.md and shared with the portal (cloud/).

/// One run of text in a slide. `b` = bold.
public struct NoteRun: Codable, Equatable, Sendable {
    public var t: String
    public var b: Bool?
    public init(_ t: String, bold: Bool = false) { self.t = t; self.b = bold ? true : nil }
    public var isBold: Bool { b ?? false }
}

public struct NoteSlide: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String      // scripture | point | quote
    public var style: String     // small | big
    public var runs: [NoteRun]
    public init(id: String, kind: String, style: String, runs: [NoteRun]) {
        self.id = id; self.kind = kind; self.style = style; self.runs = runs
    }
    /// Plain text (cue screen, control GUI).
    public var plainText: String { runs.map(\.t).joined() }
}

/// What a Mac downloads for one service (campus + date/time).
public struct ServicePackage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var campusId: String
    public var campusName: String?
    public var label: String?
    public var startsAt: String?
    public var themeId: String?
    public var messageId: String?
    public var title: String?
    public var speaker: String?
    public var version: Int
    public var updatedAt: String?
    public var slides: [NoteSlide]

    public var summary: ServiceSummary {
        ServiceSummary(id: id, campusId: campusId, campusName: campusName, label: label, startsAt: startsAt,
                       themeId: themeId, title: title, speaker: speaker, version: version, updatedAt: updatedAt)
    }
}

/// A row of the device service list (no slides).
public struct ServiceSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var campusId: String
    public var campusName: String?
    public var label: String?
    public var startsAt: String?
    public var themeId: String?
    public var title: String?
    public var speaker: String?
    public var version: Int
    public var updatedAt: String?

    public var startDate: Date? { startsAt.flatMap(ServiceSummary.parseDate) }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

// MARK: - Theme

public struct NotesTheme: Codable, Equatable, Sendable {
    public struct Layer: Codable, Equatable, Sendable {
        public var type: String           // image | rect
        public var src: String?
        public var rect: [Double]
        public var color: String?
        public var opacity: Double?
    }
    public struct Shadow: Codable, Equatable, Sendable {
        public var angle: Double
        public var offset: Double
        public var blur: Double
        public var color: String
    }
    public struct TextLook: Codable, Equatable, Sendable {
        public var color: String
        public var strokePercent: Double?
        public var strokeColor: String?
        public var shadow: Shadow?
    }
    public struct Style: Codable, Equatable, Sendable {
        public var rect: [Double]
        public var regularFont: String
        public var boldFont: String
        public var size: Double
        public var tracking: Double
        public var lineHeight: Double
        public var align: String
        public var valign: String
        public var maxLines: Int

        public var cgRect: CGRect { CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }
    }

    public var id: String
    public var name: String
    public var canvas: [Double]?
    public var layers: [Layer]
    public var text: TextLook
    public var styles: [String: Style]

    public func style(_ name: String) -> Style { styles[name] ?? styles["small"] ?? styles.values.first! }
}

/// A theme plus its decoded layer images.
public final class LoadedNotesTheme: @unchecked Sendable {
    public let theme: NotesTheme
    public let folder: URL
    public let images: [String: CGImage]
    public init(theme: NotesTheme, folder: URL, images: [String: CGImage]) {
        self.theme = theme; self.folder = folder; self.images = images
    }
}

public enum NotesThemeLibrary {
    /// Built-in notes themes: the bundle's `NotesThemes` folder, or `notes-themes/` at the repo root (dev).
    public static var builtInFolder: URL? {
        if let d = Resources.directory("NotesThemes") { return d }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("notes-themes")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDir) && isDir.boolValue ? repo : nil
    }

    public static func all() -> [LoadedNotesTheme] {
        guard let root = builtInFolder,
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(load)
    }

    public static func load(_ dir: URL) -> LoadedNotesTheme? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("theme.json")),
              let t = try? JSONDecoder().decode(NotesTheme.self, from: data) else { return nil }
        var imgs: [String: CGImage] = [:]
        for l in t.layers where l.type == "image" {
            guard let src = l.src, let s = CGImageSourceCreateWithURL(dir.appendingPathComponent(src) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { continue }
            imgs[src] = img
        }
        return LoadedNotesTheme(theme: t, folder: dir, images: imgs)
    }
}

// MARK: - Colour parsing ("#RRGGBB", "#RRGGBBAA", "rgba(r,g,b,a)")

enum CSSColor {
    static func parse(_ s: String, opacity: Double = 1) -> CGColor {
        let str = s.trimmingCharacters(in: .whitespaces).lowercased()
        var r = 0.0, g = 0.0, b = 0.0, a = 1.0
        if str.hasPrefix("#") {
            let hex = String(str.dropFirst())
            let v = UInt64(hex, radix: 16) ?? 0
            if hex.count == 8 {
                r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
                b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
            } else {
                r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
            }
        } else if let open = str.firstIndex(of: "("), let close = str.lastIndex(of: ")") {
            let nums = str[str.index(after: open)..<close].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            if nums.count >= 3 { r = nums[0] / 255; g = nums[1] / 255; b = nums[2] / 255 }
            if nums.count >= 4 { a = nums[3] }
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a * opacity)
    }
}
