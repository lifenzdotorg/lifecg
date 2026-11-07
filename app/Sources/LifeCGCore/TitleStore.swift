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
    /// When the current title will clear itself (nil = stays up until hidden).
    public var autoClearAt: Date? = nil

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
            "autoClearAt": autoClearAt.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
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
    private var autoClearWork: DispatchWorkItem?

    /// Allowed auto-clear range (seconds).
    public static let autoClearRange: ClosedRange<Double> = 0.1...600

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
            .appendingPathComponent("LifeCG", isDirectory: true)
        return dir.appendingPathComponent("recent.json")
    }

    public enum StoreError: Error, LocalizedError {
        case emptyTitle, notFound, badAutoClear
        public var errorDescription: String? {
            switch self {
            case .badAutoClear: return "autoClearSeconds must be between 0.1 and 600"
            case .emptyTitle: return "Title must not be empty"
            case .notFound: return "No such recent title"
            }
        }
    }

    /// Put a title on air.
    /// - Parameter autoClearAfter: seconds until it hides itself; nil = stays up.
    ///   Any later show/hide cancels a pending auto-clear.
    @discardableResult
    public func show(title: String, designation: String, autoClearAfter: Double? = nil) throws -> TitleEntry {
        let entry = TitleEntry(title: title, designation: designation)
        guard !entry.title.isEmpty else { throw StoreError.emptyTitle }
        if let s = autoClearAfter, !Self.autoClearRange.contains(s) { throw StoreError.badAutoClear }
        bump(entry)
        state.onAir = true
        state.current = entry
        state.last = entry
        scheduleAutoClear(autoClearAfter)
        commit(persist: true)
        return entry
    }

    private func scheduleAutoClear(_ seconds: Double?) {
        autoClearWork?.cancel()
        autoClearWork = nil
        state.autoClearAt = nil
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoClearWork = nil
            self.hide()
        }
        autoClearWork = work
        state.autoClearAt = Date().addingTimeInterval(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @discardableResult
    public func showRecent(id: String? = nil, index: Int? = nil, autoClearAfter: Double? = nil) throws -> TitleEntry {
        let found: TitleEntry?
        if let id { found = state.recent.first { $0.id == id } }
        else if let index, state.recent.indices.contains(index) { found = state.recent[index] }
        else { found = nil }
        guard let found else { throw StoreError.notFound }
        return try show(title: found.title, designation: found.designation, autoClearAfter: autoClearAfter)
    }

    public func hide() {
        guard state.onAir else { return }
        scheduleAutoClear(nil)
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
                NSLog("LifeCG: failed to save recent titles: \(error)")
            }
        }
        onChange?(state)
    }
}
