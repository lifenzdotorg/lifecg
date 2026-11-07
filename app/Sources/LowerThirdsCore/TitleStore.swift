import CryptoKit
import Foundation

/// One speaker title. `designation` is "" when absent.
public struct TitleEntry: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var designation: String
    public var lastUsed: Date

    public init(title: String, designation: String, lastUsed: Date = Date()) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.designation = designation.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = TitleEntry.makeID(title: self.title, designation: self.designation)
        self.lastUsed = lastUsed
    }

    /// Stable id: first 8 hex chars of SHA-256(lower(title) + "\n" + lower(designation)).
    public static func makeID(title: String, designation: String) -> String {
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\n"
            + designation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// Snapshot broadcast to every client (see docs/PROTOCOL.md).
public struct TitleState: Equatable, Sendable {
    public var onAir: Bool
    public var current: TitleEntry?
    public var last: TitleEntry?
    public var recent: [TitleEntry]

    public func jsonObject() -> [String: Any] {
        func entry(_ e: TitleEntry?, withDate: Bool = false) -> Any {
            guard let e else { return NSNull() }
            var d: [String: Any] = ["id": e.id, "title": e.title, "designation": e.designation]
            if withDate { d["lastUsed"] = ISO8601DateFormatter().string(from: e.lastUsed) }
            return d
        }
        return [
            "type": "state",
            "protocol": 1,
            "onAir": onAir,
            "current": entry(current),
            "last": entry(last),
            "recent": recent.map { entry($0, withDate: true) },
        ]
    }
}

/// Holds on-air state and the persisted Recent list. Main-thread only.
public final class TitleStore {
    public static let maxRecent = 20

    public private(set) var state: TitleState
    /// Called after every state change.
    public var onChange: ((TitleState) -> Void)?

    private let fileURL: URL?

    /// - Parameter fileURL: where Recent is persisted (nil = in-memory only, for tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        var recent: [TitleEntry] = []
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            recent = (try? dec.decode([TitleEntry].self, from: data)) ?? []
        }
        state = TitleState(onAir: false, current: nil, last: recent.first, recent: Array(recent.prefix(Self.maxRecent)))
    }

    public static var defaultFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LowerThirds", isDirectory: true)
        return dir.appendingPathComponent("recent.json")
    }

    public enum StoreError: Error, LocalizedError {
        case emptyTitle, notFound
        public var errorDescription: String? {
            switch self {
            case .emptyTitle: return "Title must not be empty"
            case .notFound: return "No such recent title"
            }
        }
    }

    @discardableResult
    public func show(title: String, designation: String) throws -> TitleEntry {
        let entry = TitleEntry(title: title, designation: designation)
        guard !entry.title.isEmpty else { throw StoreError.emptyTitle }
        bump(entry)
        state.onAir = true
        state.current = entry
        state.last = entry
        commit(persist: true)
        return entry
    }

    @discardableResult
    public func showRecent(id: String? = nil, index: Int? = nil) throws -> TitleEntry {
        let found: TitleEntry?
        if let id { found = state.recent.first { $0.id == id } }
        else if let index, state.recent.indices.contains(index) { found = state.recent[index] }
        else { found = nil }
        guard let found else { throw StoreError.notFound }
        return try show(title: found.title, designation: found.designation)
    }

    public func hide() {
        guard state.onAir else { return }
        state.onAir = false
        state.current = nil
        commit(persist: false)
    }

    public func toggle() {
        if state.onAir { hide() }
        else if let last = state.last { _ = try? show(title: last.title, designation: last.designation) }
    }

    public func removeRecent(id: String) {
        state.recent.removeAll { $0.id == id }
        commit(persist: true)
    }

    public func clearRecent() {
        state.recent.removeAll()
        commit(persist: true)
    }

    private func bump(_ entry: TitleEntry) {
        state.recent.removeAll { $0.id == entry.id }
        state.recent.insert(entry, at: 0)
        if state.recent.count > Self.maxRecent { state.recent.removeLast(state.recent.count - Self.maxRecent) }
    }

    private func commit(persist: Bool) {
        if persist, let fileURL {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted]
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try enc.encode(state.recent).write(to: fileURL, options: .atomic)
            } catch {
                NSLog("LowerThirds: failed to save recent titles: \(error)")
            }
        }
        onChange?(state)
    }
}
