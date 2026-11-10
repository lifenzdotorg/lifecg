import Foundation

/// Speaker-notes state for this Mac: which service is loaded, what is live, what the cue screen
/// shows as "next", and the local cache of downloaded services. Main thread only.
///
/// Cue screen "next":
/// - a slide the operator *previewed* (shown as next without going live), else
/// - the slide after the live one (or after the last live one once cleared), else the first slide.
/// - **Clear All** blanks it until the operator picks a slide again.
public final class NotesController {
    public struct Settings: Codable, Equatable {
        public var portalURL: String = ""
        public var deviceToken: String = ""
        /// Cloudflare Access service token (the portal sits behind Access; Macs authenticate with this).
        public var accessClientID: String = ""
        public var accessClientSecret: String = ""
        public init() {}
        public var isConfigured: Bool { !portalURL.isEmpty && !deviceToken.isEmpty }
    }

    public struct SyncStatus: Equatable {
        public var lastSuccess: Date?
        public var lastError: String?
        public var deviceName: String?
        public var campusId: String?
    }

    // Loaded service and output state
    public private(set) var loaded: ServicePackage?
    public private(set) var themeOverride: String?
    public private(set) var liveIndex: Int?
    public private(set) var previewIndex: Int?
    public private(set) var lastLiveIndex: Int?
    public private(set) var nextBlank = false
    /// A newer version of the loaded service is in the cache, waiting for the operator.
    public private(set) var pendingUpdate: ServicePackage?

    // Library
    public private(set) var services: [ServiceSummary] = []        // this Mac's campus, from the portal
    public private(set) var otherServices: [ServiceSummary] = []   // all campuses (on request)
    public private(set) var cached: [String: ServicePackage] = [:]
    public private(set) var sync = SyncStatus()
    public var settings: Settings { didSet { if settings != oldValue { restartSync() } } }

    /// Fired after every change (main thread).
    public var onChange: ((NotesController) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Default theme id when a service names none or one this Mac doesn't have.
    public var fallbackThemeID = "central"
    public var availableThemeIDs: Set<String> = []
    public var appVersion = "dev"

    private let cacheDir: URL?
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private let session: URLSession

    public static var defaultCacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LifeCG/Notes", isDirectory: true)
    }

    public init(cacheDir: URL? = NotesController.defaultCacheDir, settings: Settings = Settings()) {
        self.cacheDir = cacheDir
        self.settings = settings
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        loadCache()
    }

    // MARK: - Derived

    public var themeID: String {
        let want = themeOverride ?? loaded?.themeId ?? fallbackThemeID
        return availableThemeIDs.isEmpty || availableThemeIDs.contains(want) ? want : fallbackThemeID
    }

    public var slides: [NoteSlide] { loaded?.slides ?? [] }
    public var liveSlide: NoteSlide? { liveIndex.flatMap { slides.indices.contains($0) ? slides[$0] : nil } }

    public var nextIndex: Int? {
        guard !nextBlank, !slides.isEmpty else { return nil }
        if let p = previewIndex { return slides.indices.contains(p) ? p : nil }
        if let l = liveIndex ?? lastLiveIndex { return l + 1 < slides.count ? l + 1 : nil }
        return 0
    }
    public var nextSlide: NoteSlide? { nextIndex.map { slides[$0] } }

    /// Upcoming services from the portal plus anything cached, soonest first.
    public var serviceList: [ServiceSummary] {
        var byID: [String: ServiceSummary] = [:]
        for p in cached.values { byID[p.id] = p.summary }
        for s in services + otherServices { byID[s.id] = s }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        return byID.values
            .filter { ($0.startDate ?? .distantFuture) >= cutoff || $0.id == loaded?.id }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    // MARK: - Operator actions

    public func goLive(_ index: Int) {
        guard slides.indices.contains(index) else { return }
        liveIndex = index; lastLiveIndex = index
        previewIndex = nil; nextBlank = false
        changed()
    }

    /// Show `index` as "next" on the cue screen only.
    public func preview(_ index: Int) {
        guard slides.indices.contains(index) else { return }
        previewIndex = index; nextBlank = false
        changed()
    }

    public func goNext() {
        if let n = nextIndex { goLive(n) }
        else if liveIndex == nil, let l = lastLiveIndex, l + 1 < slides.count { goLive(l + 1) }
    }

    public func goPrevious() {
        let base = liveIndex ?? lastLiveIndex ?? 1
        if base - 1 >= 0 { goLive(base - 1) }
    }

    /// Take the current slide off the main output. The cue screen keeps showing "next".
    public func clear() {
        guard liveIndex != nil else { return }
        liveIndex = nil
        changed()
    }

    /// Take the slide off and blank "next" on the cue screen too.
    public func clearAll() {
        guard liveIndex != nil || !nextBlank || previewIndex != nil else { return }
        liveIndex = nil; previewIndex = nil; nextBlank = true
        changed()
    }

    public func setThemeOverride(_ id: String?) {
        themeOverride = (id == nil || id == loaded?.themeId) ? nil : id
        changed()
    }

    /// Load a cached service (fetching it first if needed). Output is cleared.
    public func load(serviceID: String, completion: ((Bool) -> Void)? = nil) {
        if let p = cached[serviceID] {
            activate(p)
            completion?(true)
            return
        }
        fetchPackage(serviceID) { [weak self] p in
            guard let self, let p else { completion?(false); return }
            self.activate(p)
            completion?(true)
        }
    }

    /// Accept the pending update: swap in the new version and keep the operator's place where it still exists.
    public func applyUpdate() {
        guard let p = pendingUpdate else { return }
        let liveID = liveSlide?.id, prevID = previewIndex.map { slides[$0].id }, lastID = lastLiveIndex.flatMap { slides.indices.contains($0) ? slides[$0].id : nil }
        loaded = p
        pendingUpdate = nil
        func find(_ id: String?, _ old: Int?) -> Int? {
            if let id, let i = p.slides.firstIndex(where: { $0.id == id }) { return i }
            if let old, p.slides.indices.contains(old) { return old }
            return nil
        }
        liveIndex = liveIndex == nil ? nil : find(liveID, liveIndex)
        previewIndex = previewIndex == nil ? nil : find(prevID, previewIndex)
        lastLiveIndex = lastLiveIndex == nil ? nil : find(lastID, lastLiveIndex)
        onLog?("Notes updated to version \(p.version): \(p.title ?? p.id)")
        changed()
    }

    /// Tests only: pretend the portal delivered a newer version of the loaded service.
    public func setPendingForTesting(_ p: ServicePackage) { pendingUpdate = p }

    /// Add a package from a file (testing / offline use). Loads it.
    public func importPackage(_ data: Data) throws {
        let p = try JSONDecoder().decode(ServicePackage.self, from: data)
        store(p)
        activate(p)
    }

    private func activate(_ p: ServicePackage) {
        loaded = p
        themeOverride = nil
        liveIndex = nil; previewIndex = nil; lastLiveIndex = nil; nextBlank = false
        pendingUpdate = nil
        onLog?("Notes loaded: \(p.label ?? p.campusId) — \(p.title ?? "") (v\(p.version), \(p.slides.count) slides)")
        UserDefaults.standard.set(p.id, forKey: "notes.loadedServiceID")
        changed()
    }

    private func changed() { onChange?(self) }

    // MARK: - Cache

    private func loadCache() {
        guard let dir = cacheDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(ServicePackage.self, from: d) { cached[p.id] = p }
        }
        if let id = UserDefaults.standard.string(forKey: "notes.loadedServiceID"), let p = cached[id] {
            loaded = p
        }
    }

    private func store(_ p: ServicePackage) {
        cached[p.id] = p
        guard let dir = cacheDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(p) { try? d.write(to: dir.appendingPathComponent(Self.fileName(p.id)), options: .atomic) }
    }

    private static func fileName(_ id: String) -> String {
        id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined() + ".json"
    }

    // MARK: - Sync with the portal

    public func startSync() { restartSync() }

    private func restartSync() {
        timer?.cancel(); timer = nil
        guard settings.isConfigured else { return }
        // A dispatch timer (not a RunLoop timer) so it also runs under dispatchMain (lt-render --serve).
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.syncNow() }
        t.resume()
        timer = t
    }

    public static let pollInterval: TimeInterval = 15

    public func stopSync() { timer?.cancel(); timer = nil }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        let base = settings.portalURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(settings.deviceToken)", forHTTPHeaderField: "Authorization")
        if !settings.accessClientID.isEmpty {
            r.setValue(settings.accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            r.setValue(settings.accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        r.setValue("LifeCG/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private struct ListResponse: Decodable {
        struct Device: Decodable { var id: String?; var name: String?; var campusId: String? }
        var device: Device?
        var services: [ServiceSummary]
    }

    private func get<T: Decodable>(_ path: String, _ type: T.Type, completion: @escaping (Result<T, Error>) -> Void) {
        guard let req = request(path) else { completion(.failure(URLError(.badURL))); return }
        session.dataTask(with: req) { data, resp, err in
            let result: Result<T, Error>
            if let err { result = .failure(err) }
            else if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(NSError(domain: "LifeCG", code: http.statusCode,
                                          userInfo: [NSLocalizedDescriptionKey: "Portal returned HTTP \(http.statusCode)"]))
            } else {
                do { result = .success(try JSONDecoder().decode(T.self, from: data ?? Data())) }
                catch { result = .failure(error) }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: Operator sign-in (LIFE login on the control GUI)

    public struct OperatorIdentity: Equatable {
        public var email: String
        public var name: String?
        public var role: String
    }

    /// Where the control GUI sends people to sign in with their LIFE login (nil when the portal isn't set up).
    public var operatorSignInURL: String? {
        guard settings.isConfigured else { return nil }
        return settings.portalURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/operator/signin"
    }

    /// POST to the device API. `status` 0 = portal unreachable.
    private func postJSON(_ path: String, _ body: [String: Any], completion: @escaping (Int, [String: Any]?) -> Void) {
        guard settings.isConfigured, let data = try? JSONSerialization.data(withJSONObject: body),
              var req = request(path, method: "POST", body: data) else { completion(0, nil); return }
        req.timeoutInterval = 10
        session.dataTask(with: req) { data, resp, err in
            let status = err == nil ? ((resp as? HTTPURLResponse)?.statusCode ?? 0) : 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async { completion(status, obj) }
        }.resume()
    }

    /// Redeem the one-time code the portal put in the redirect back to the control GUI.
    public func redeemOperatorCode(_ code: String, completion: @escaping (OperatorIdentity?, String?) -> Void) {
        postJSON("/api/device/operator/redeem", ["code": code]) { status, obj in
            if status == 200, let email = obj?["email"] as? String, let role = obj?["role"] as? String {
                completion(OperatorIdentity(email: email, name: obj?["name"] as? String, role: role), nil)
            } else if status == 0 {
                completion(nil, "LifeCG can't reach the notes portal. Use the PIN instead.")
            } else {
                // Access answers a bad service token with its login page (HTML), so there's no JSON error.
                completion(nil, (obj?["error"] as? String) ?? "The portal refused the sign-in (HTTP \(status)). Check LifeCG's portal settings.")
            }
        }
    }

    /// Is this person still allowed to run the CG Macs? nil = couldn't ask the portal.
    public func checkOperator(_ email: String, completion: @escaping (Bool?) -> Void) {
        postJSON("/api/device/operator/check", ["email": email]) { status, obj in
            completion(status == 200 ? (obj?["allowed"] as? Bool) : nil)
        }
    }

    private func fetchPackage(_ id: String, completion: @escaping (ServicePackage?) -> Void) {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        get("/api/device/services/\(enc)", ServicePackage.self) { [weak self] r in
            switch r {
            case .success(let p): self?.store(p); completion(p)
            case .failure(let e): self?.onLog?("Notes: download failed: \(e.localizedDescription)"); completion(nil)
            }
        }
    }

    /// Poll the portal once: refresh the service list, download changed packages, flag updates.
    public func syncNow(allCampuses: Bool = false) {
        guard settings.isConfigured, !inFlight else { return }
        inFlight = true
        get(allCampuses ? "/api/device/services?campus=all" : "/api/device/services", ListResponse.self) { [weak self] r in
            guard let self else { return }
            self.inFlight = false
            switch r {
            case .failure(let e):
                let msg = e.localizedDescription
                if self.sync.lastError != msg { self.onLog?("Notes sync: \(msg)") }
                self.sync.lastError = msg
                self.changed()
            case .success(let list):
                if self.sync.lastError != nil { self.onLog?("Notes sync: connected") }
                self.sync.lastError = nil
                self.sync.lastSuccess = Date()
                self.sync.deviceName = list.device?.name
                self.sync.campusId = list.device?.campusId
                if allCampuses { self.otherServices = list.services } else { self.services = list.services }
                self.downloadChanged(list.services)
                self.heartbeat()
                self.changed()
            }
        }
    }

    private func downloadChanged(_ list: [ServiceSummary]) {
        for s in list where (cached[s.id]?.version ?? -1) != s.version {
            fetchPackage(s.id) { [weak self] p in
                guard let self, let p else { return }
                if p.id == self.loaded?.id, p.version != self.loaded?.version {
                    self.pendingUpdate = p
                    self.onLog?("Notes: updated version \(p.version) available for \(p.label ?? p.id)")
                } else if self.loaded == nil, s.id == list.first?.id {
                    self.activate(p)   // nothing loaded yet: take the soonest service for this campus
                }
                self.changed()
            }
        }
        // A newer version may already be cached (e.g. downloaded before the operator loaded the old one).
        if let l = loaded, let c = cached[l.id], c.version != l.version, pendingUpdate?.version != c.version {
            pendingUpdate = c
        }
    }

    private func heartbeat() {
        let body: [String: Any] = ["appVersion": appVersion, "loadedServiceId": nz(loaded?.id), "loadedVersion": nz(loaded?.version)]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let req = request("/api/device/heartbeat", method: "POST", body: data) else { return }
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    // MARK: - JSON for the control GUI

    public func jsonObject(themes: [(id: String, name: String)], titleOnAir: Bool, lineCounts: [Int]) -> [String: Any] {
        func summary(_ s: ServiceSummary) -> [String: Any] {
            ["id": s.id, "campusId": s.campusId, "campusName": nz(s.campusName), "label": nz(s.label),
             "startsAt": nz(s.startsAt), "title": nz(s.title), "speaker": nz(s.speaker), "version": s.version,
             "themeId": nz(s.themeId)]
        }
        let slidesJSON: [[String: Any]] = slides.enumerated().map { i, s in
            [
                "i": i, "id": s.id, "kind": s.kind, "style": s.style,
                "runs": s.runs.map { ["t": $0.t, "b": $0.isBold] },
                "lines": i < lineCounts.count ? lineCounts[i] : 0,
            ]
        }
        let iso = ISO8601DateFormatter()
        return [
            "type": "notes",
            "service": nz(loaded.map { summary($0.summary) }),
            "slides": slidesJSON,
            "live": nz(liveIndex),
            "next": nz(nextIndex),
            "preview": nz(previewIndex),
            "nextBlank": nextBlank,
            "pendingUpdate": nz(pendingUpdate.map { ["version": $0.version, "updatedAt": nz($0.updatedAt)] }),
            "services": serviceList.map(summary),
            "themeId": themeID,
            "themes": themes.map { ["id": $0.id, "name": $0.name] },
            "titleOnAir": titleOnAir,
            "sync": [
                "configured": settings.isConfigured,
                "lastSuccess": nz(sync.lastSuccess.map { iso.string(from: $0) }),
                "error": nz(sync.lastError),
                "device": nz(sync.deviceName),
                "campusId": nz(sync.campusId),
            ],
        ]
    }
}

/// JSON-safe optional: nil → NSNull.
func nz(_ v: Any?) -> Any { v ?? NSNull() }
