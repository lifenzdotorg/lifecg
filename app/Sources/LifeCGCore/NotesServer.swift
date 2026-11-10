import CryptoKit
import Foundation
import Security

/// A control-GUI sign-in. PIN sign-ins last 12 h and are never remembered; LIFE (portal) sign-ins by
/// operators can be remembered on the device for 30 days and are kept across restarts.
public struct NotesSession: Codable, Equatable {
    public var kind: String          // "pin" | "operator"
    public var email: String?
    public var name: String?
    public var remember: Bool
    public var expires: Date
    public var checked: Date         // last time the portal confirmed the operator role
}

/// Speaker-notes control GUI routes on the control server (LAN only).
///
///   GET  /control                     the web app (iPad / desktop / phone)
///   GET  /api/notes/loginOptions      → {signInURL?}: LIFE sign-in available when the portal is set up
///   POST /api/notes/login {pin}       → {session, user}
///   POST /api/notes/login {code, remember}  LIFE sign-in: one-time code from the portal redirect
///   GET  /api/notes/me                → {kind, email?, name?, remember}
///   POST /api/notes/logout
///   GET  /notes/ws?s=<session>        WebSocket: notes state pushed on every change; accepts {type: action, …}
///   GET  /api/notes/state             current state
///   POST /api/notes/<action>          live {index} · preview {index} · next · previous · clear · clearAll ·
///                                     load {serviceId} · applyUpdate · theme {id} · refresh {all}
///   GET  /api/notes/thumb/<i>.png     rendered lower-third crop of slide i
///
/// The session token goes in the `X-LifeCG-Session` header or the `s` query parameter.
extension ControlServer {
    static let maxPinFailures = 5
    static let pinLockout: TimeInterval = 60
    static let shortSession: TimeInterval = 12 * 3600
    static let rememberedSession: TimeInterval = 30 * 86400
    static let operatorRecheck: TimeInterval = 6 * 3600

    /// Returns true when the request was a notes route (handled here).
    func handleNotesHTTP(_ req: HTTPRequest, path: String, on c: Connection) -> Bool {
        guard path == "/control" || path == "/control/" || path.hasPrefix("/api/notes/") || path == "/notes/ws" else { return false }
        let query = Self.queryItems(req.path)
        let token = req.headers["x-lifecg-session"] ?? query["s"] ?? ""
        func json(_ code: Int, _ obj: Any) { c.respond(code, Self.json(obj)) }

        if req.method == "OPTIONS" { c.respond(204, ""); return true }

        if path == "/control" || path == "/control/" {
            if let dir = Resources.directory("Web"), let html = try? Data(contentsOf: dir.appendingPathComponent("control.html")) {
                c.respondData(200, html, contentType: "text/html; charset=utf-8", extraHeaders: "Cache-Control: no-store\r\n")
            } else {
                c.respond(404, "Control GUI files missing from this build", contentType: "text/plain")
            }
            return true
        }

        guard let hub = notesHub else { json(503, ["type": "error", "message": "Notes not available"]); return true }

        if path == "/api/notes/loginOptions", req.method == "GET" {
            json(200, ["signInURL": (hub.controller.operatorSignInURL as Any?) ?? NSNull()]); return true
        }

        if path == "/api/notes/login", req.method == "POST" {
            let addr = c.address
            if let f = notesFailures[addr], f.count >= Self.maxPinFailures, f.until > Date() {
                json(429, ["type": "error", "message": "Too many failed sign-ins. Try again in a minute."]); return true
            }
            func failed(_ message: String) {
                var f = notesFailures[addr] ?? (0, Date())
                f.count += 1
                f.until = Date().addingTimeInterval(Self.pinLockout)
                notesFailures[addr] = f
                json(401, ["type": "error", "message": message])
            }
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]

            if let code = body["code"] as? String, !code.isEmpty {
                let remember = (body["remember"] as? Bool) == true
                hub.controller.redeemOperatorCode(code) { [weak self] who, err in
                    guard let self else { return }
                    guard let who else {
                        self.onLog?("Control GUI: LIFE sign-in failed from \(addr): \(err ?? "")")
                        failed(err ?? "Sign-in failed"); return
                    }
                    self.notesFailures[addr] = nil
                    let now = Date()
                    let s = NotesSession(kind: "operator", email: who.email, name: who.name, remember: remember,
                                         expires: now.addingTimeInterval(remember ? Self.rememberedSession : Self.shortSession), checked: now)
                    let t = self.addNotesSession(s)
                    self.onLog?("Control GUI: \(who.email) signed in from \(addr)\(remember ? " (remembered)" : "")")
                    json(200, ["session": t, "user": Self.sessionJSON(s)])
                }
                return true
            }

            let pin = (body["pin"] as? String) ?? (body["pin"] as? NSNumber)?.stringValue ?? ""
            let expected = notesPIN()
            guard !expected.isEmpty, pin == expected else {
                onLog?("Control GUI: wrong PIN from \(addr)")
                failed("Wrong PIN"); return true
            }
            notesFailures[addr] = nil
            let s = NotesSession(kind: "pin", email: nil, name: nil, remember: false,
                                 expires: Date().addingTimeInterval(Self.shortSession), checked: Date())
            let t = addNotesSession(s)
            onLog?("Control GUI: signed in with the PIN from \(addr)")
            json(200, ["session": t, "user": Self.sessionJSON(s)])
            return true
        }

        let key = Self.sessionKey(token)
        guard !token.isEmpty, let sess = notesSessions[key], sess.expires > Date() else {
            if !token.isEmpty, notesSessions[key] != nil { removeNotesSession(key) }
            json(401, ["type": "error", "message": "Sign in again"]); return true
        }
        recheckOperatorIfDue(key, sess, hub: hub)

        if path == "/api/notes/me", req.method == "GET" { json(200, Self.sessionJSON(sess)); return true }
        if path == "/api/notes/logout", req.method == "POST" {
            onLog?("Control GUI: \(sess.email ?? "PIN user") signed out")
            removeNotesSession(key)
            json(200, ["ok": true]); return true
        }

        if path == "/notes/ws", req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            c.sendRaw("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n")
            c.isWebSocket = true
            c.isNotesClient = true
            c.notesSessionKey = key
            c.info = ClientInfo(id: c.id, name: "Control GUI (\(sess.name ?? sess.email ?? c.address))", kind: "notes-control", address: c.address)
            c.onText = { [weak self, weak c] text in
                guard let self, let c else { return }
                let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                if (obj["type"] as? String) == "ping" { c.sendText(#"{"type":"pong"}"#); return }
                if let err = self.notesAction(obj["type"] as? String ?? "", obj, hub: hub) {
                    c.sendText(Self.json(["type": "error", "message": err]))
                }
            }
            updateClients()
            c.sendText(Self.json(hub.stateJSON()))
            return true
        }

        if path.hasPrefix("/api/notes/thumb/"), req.method == "GET" {
            let name = path.dropFirst("/api/notes/thumb/".count).replacingOccurrences(of: ".png", with: "")
            guard let i = Int(name) else { json(404, ["type": "error", "message": "Not found"]); return true }
            hub.thumbnail(i) { data in
                if let data { c.respondData(200, data, contentType: "image/png", extraHeaders: "Cache-Control: private, max-age=600\r\n") }
                else { c.respond(404, Self.json(["type": "error", "message": "No such slide"])) }
            }
            return true
        }

        if path == "/api/notes/state", req.method == "GET" { json(200, hub.stateJSON()); return true }

        if req.method == "POST" {
            let action = String(path.dropFirst("/api/notes/".count))
            let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            if let err = notesAction(action, body, hub: hub) { json(400, ["type": "error", "message": err]) }
            else { json(200, hub.stateJSON()) }
            return true
        }
        json(404, ["type": "error", "message": "Not found"])
        return true
    }

    /// Perform a control-GUI action. Returns an error message, or nil on success.
    func notesAction(_ action: String, _ body: [String: Any], hub: NotesHub) -> String? {
        let n = hub.controller
        let index = (body["index"] as? NSNumber)?.intValue
        switch action {
        case "live":
            guard let i = index, n.slides.indices.contains(i) else { return "No such slide" }
            n.goLive(i)
        case "preview":
            guard let i = index, n.slides.indices.contains(i) else { return "No such slide" }
            n.preview(i)
        case "next": n.goNext()
        case "previous": n.goPrevious()
        case "clear": n.clear()
        case "clearAll": n.clearAll()
        case "applyUpdate": n.applyUpdate()
        case "load":
            guard let id = body["serviceId"] as? String else { return "serviceId missing" }
            n.load(serviceID: id) { [weak self] ok in if !ok { self?.onLog?("Notes: could not load \(id)") } }
        case "theme":
            let id = body["id"] as? String
            n.setThemeOverride(id?.isEmpty == false ? id : nil)
        case "refresh":
            n.syncNow(allCampuses: (body["all"] as? Bool) == true)
        default:
            return "Unknown action: \(action)"
        }
        return nil
    }

    /// Push the notes state to every control GUI.
    public func broadcastNotes() {
        guard let hub = notesHub else { return }
        let clients = connections.values.filter { $0.isWebSocket && $0.isNotesClient }
        guard !clients.isEmpty else { return }
        let text = Self.json(hub.stateJSON())
        for c in clients { c.sendText(text) }
    }

    /// Sign control GUIs out: `kind` "pin" after the PIN changes, "operator" for LIFE sign-ins, nil for everyone.
    public func resetNotesSessions(kind: String? = nil) {
        let keys = notesSessions.filter { kind == nil || $0.value.kind == kind }.map(\.key)
        for k in keys { notesSessions[k] = nil }
        for c in connections.values where c.isNotesClient && (c.notesSessionKey.map { keys.contains($0) } ?? true) { c.nw.cancel() }
        saveNotesSessions()
    }

    /// Who is signed in with a LIFE login (for the Mac's settings).
    public var operatorSessions: [NotesSession] {
        notesSessions.values.filter { $0.kind == "operator" && $0.expires > Date() }.sorted { ($0.email ?? "") < ($1.email ?? "") }
    }

    func addNotesSession(_ s: NotesSession) -> String {
        let t = Self.newToken()
        notesSessions = notesSessions.filter { $0.value.expires > Date() }
        notesSessions[Self.sessionKey(t)] = s
        if s.remember { saveNotesSessions() }
        return t
    }

    func removeNotesSession(_ key: String) {
        let was = notesSessions.removeValue(forKey: key)
        for c in connections.values where c.isNotesClient && c.notesSessionKey == key { c.nw.cancel() }
        if was?.remember == true { saveNotesSessions() }
    }

    /// A remembered operator might have been demoted in the portal: ask again every few hours.
    /// If the portal can't be reached the sign-in stays (the church network may be offline).
    func recheckOperatorIfDue(_ key: String, _ s: NotesSession, hub: NotesHub) {
        guard s.kind == "operator", let email = s.email, Date().timeIntervalSince(s.checked) > Self.operatorRecheck else { return }
        notesSessions[key]?.checked = Date()
        hub.controller.checkOperator(email) { [weak self] allowed in
            guard let self, allowed == false else { return }
            self.onLog?("Control GUI: \(email) is no longer an operator; signed out")
            self.removeNotesSession(key)
        }
    }

    static func sessionKey(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sessionJSON(_ s: NotesSession) -> [String: Any] {
        ["kind": s.kind, "email": (s.email as Any?) ?? NSNull(), "name": (s.name as Any?) ?? NSNull(), "remember": s.remember]
    }

    func loadNotesSessions() {
        guard let url = notesSessionFile, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let saved = try? dec.decode([String: NotesSession].self, from: data) else { return }
        for (k, v) in saved where v.remember && v.expires > Date() { notesSessions[k] = v }
    }

    func saveNotesSessions() {
        guard let url = notesSessionFile else { return }
        let keep = notesSessions.filter { $0.value.remember && $0.value.expires > Date() }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(keep) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func queryItems(_ rawPath: String) -> [String: String] {
        guard let q = rawPath.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}
