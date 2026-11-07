import CryptoKit
import Foundation
import Network

/// HTTP + WebSocket control server on one port (see docs/PROTOCOL.md).
/// Minimal HTTP/1.1 and RFC 6455 implementation on Network.framework — no dependencies.
/// All callbacks into the store happen on the main queue.
public final class ControlServer {
    public struct ClientInfo: Equatable {
        public let id: Int
        public var name: String
        public var kind: String
        public let address: String
    }

    public private(set) var clients: [ClientInfo] = []
    public var onClientsChanged: (([ClientInfo]) -> Void)?
    public var onLog: ((String) -> Void)?

    private let store: TitleStore
    private var listener: NWListener?
    private var connections: [Int: Connection] = [:]
    private var nextID = 1
    public private(set) var port: UInt16 = 0

    public init(store: TitleStore) {
        self.store = store
    }

    public func start(port: UInt16) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.onLog?("Control server listening on port \(port)")
            case .failed(let e): self?.onLog?("Control server failed: \(e)")
            default: break
            }
        }
        l.start(queue: .main)
        listener = l
        self.port = port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.nw.cancel() }
        connections.removeAll()
        updateClients()
    }

    /// Push the current state to every WebSocket client.
    public func broadcast(_ state: TitleState) {
        let text = Self.json(state.jsonObject())
        for c in connections.values where c.isWebSocket { c.sendText(text) }
    }

    // MARK: - Connections

    private func accept(_ nw: NWConnection) {
        let id = nextID; nextID += 1
        let c = Connection(id: id, nw: nw)
        c.onRequest = { [weak self, weak c] req in
            guard let self, let c else { return }
            self.handleHTTP(req, on: c)
        }
        c.onText = { [weak self, weak c] text in
            guard let self, let c else { return }
            self.handleMessage(text, from: c)
        }
        c.onClose = { [weak self] in
            guard let self else { return }
            if let c = self.connections.removeValue(forKey: id), c.isWebSocket {
                self.onLog?("Client disconnected: \(c.info?.name ?? c.address)")
            }
            self.updateClients()
        }
        connections[id] = c
        c.start()
    }

    private func updateClients() {
        clients = connections.values.filter(\.isWebSocket).compactMap(\.info).sorted { $0.id < $1.id }
        onClientsChanged?(clients)
    }

    // MARK: - HTTP

    private func handleHTTP(_ req: HTTPRequest, on c: Connection) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        if path == "/ws", req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            c.sendRaw("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n")
            c.isWebSocket = true
            c.info = ClientInfo(id: c.id, name: c.address, kind: "unknown", address: c.address)
            onLog?("Client connected: \(c.address)")
            updateClients()
            c.sendText(Self.json(store.state.jsonObject()))
            return
        }

        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        let autoClear = (body["autoClearSeconds"] as? NSNumber)?.doubleValue
        func ok() { c.respond(200, Self.json(store.state.jsonObject())) }
        func bad(_ msg: String, _ code: Int = 400) { c.respond(code, Self.json(["type": "error", "message": msg])) }

        switch (req.method, path) {
        case ("OPTIONS", _): c.respond(204, "")
        case ("GET", "/api/state"): ok()
        case ("GET", "/"):
            c.respond(200, "LifeCG is running. See /api/state", contentType: "text/plain")
        case ("POST", "/api/show"):
            do { try store.show(title: body["title"] as? String ?? "", designation: body["designation"] as? String ?? "", autoClearAfter: autoClear); ok() }
            catch { bad(error.localizedDescription) }
        case ("POST", "/api/hide"): store.hide(); ok()
        case ("POST", "/api/toggle"): store.toggle(); ok()
        case ("POST", "/api/recent/clear"): store.clearRecent(); ok()
        case ("POST", "/sistas21/remote/speakertitle"):
            // Legacy NodeCG-compatible endpoint used by the old Companion module.
            if (body["action"] as? String) == "go" {
                do { try store.show(title: body["name"] as? String ?? "", designation: body["designation"] as? String ?? ""); ok() }
                catch { bad(error.localizedDescription) }
            } else { store.hide(); ok() }
        default: bad("Not found", 404)
        }
    }

    // MARK: - WebSocket messages

    private func handleMessage(_ text: String, from c: Connection) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else {
            c.sendText(Self.json(["type": "error", "message": "Invalid JSON"])); return
        }
        func err(_ m: String) { c.sendText(Self.json(["type": "error", "message": m])) }
        do {
            switch type {
            case "hello":
                let name = obj["name"] as? String ?? c.address
                c.info = ClientInfo(id: c.id, name: name, kind: obj["client"] as? String ?? "unknown", address: c.address)
                onLog?("Client identified: \(name) (\(c.info!.kind)) from \(c.address)")
                updateClients()
                c.sendText(Self.json(store.state.jsonObject()))
            case "show":
                try store.show(title: obj["title"] as? String ?? "", designation: obj["designation"] as? String ?? "",
                               autoClearAfter: (obj["autoClearSeconds"] as? NSNumber)?.doubleValue)
            case "showRecent":
                try store.showRecent(id: obj["id"] as? String, index: (obj["index"] as? NSNumber)?.intValue,
                                     autoClearAfter: (obj["autoClearSeconds"] as? NSNumber)?.doubleValue)
            case "hide": store.hide()
            case "toggle": store.toggle()
            case "removeRecent": store.removeRecent(id: obj["id"] as? String ?? "")
            case "clearRecent": store.clearRecent()
            case "ping": c.sendText(#"{"type":"pong"}"#)
            default: err("Unknown message type: \(type)")
            }
        } catch {
            err(error.localizedDescription)
        }
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Connection

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

private final class Connection {
    let id: Int
    let nw: NWConnection
    var isWebSocket = false
    var info: ControlServer.ClientInfo?
    var onRequest: ((HTTPRequest) -> Void)?
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var closed = false
    private var fragments = Data()
    private static let maxBuffer = 1 << 20

    var address: String {
        if case let .hostPort(host, _) = nw.endpoint {
            return "\(host)".replacingOccurrences(of: "::ffff:", with: "").components(separatedBy: "%").first ?? "\(host)"
        }
        return "\(nw.endpoint)"
    }

    init(id: Int, nw: NWConnection) { self.id = id; self.nw = nw }

    func start() {
        nw.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: .main)
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > Self.maxBuffer { self.close(); return }
                self.process()
            }
            if done || error != nil { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        nw.cancel()
        onClose?()
    }

    private func process() {
        while !closed {
            if isWebSocket {
                guard parseFrame() else { return }
            } else {
                guard parseHTTP() else { return }
            }
        }
    }

    // HTTP/1.1 request (Content-Length bodies only — no chunked uploads needed here).
    private func parseHTTP() -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { close(); return false }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= len else { return false }
        let body = buffer[bodyStart..<(bodyStart + len)]
        buffer = Data(buffer[(bodyStart + len)...])
        onRequest?(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body)))
        return true
    }

    // RFC 6455 frame from a client (always masked).
    private func parseFrame() -> Bool {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return false }
        let fin = b[0] & 0x80 != 0
        let opcode = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7F)
        var offset = 2
        if len == 126 {
            guard b.count >= 4 else { return false }
            len = Int(b[2]) << 8 | Int(b[3]); offset = 4
        } else if len == 127 {
            guard b.count >= 10 else { return false }
            len = 0; for i in 2..<10 { len = len << 8 | Int(b[i]) }; offset = 10
        }
        guard len < Self.maxBuffer else { close(); return false }
        let maskLen = masked ? 4 : 0
        guard buffer.count >= offset + maskLen + len else { return false }
        let start = buffer.startIndex
        let mask = masked ? [UInt8](buffer[(start + offset)..<(start + offset + 4)]) : [0, 0, 0, 0]
        var payload = [UInt8](buffer[(start + offset + maskLen)..<(start + offset + maskLen + len)])
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        buffer = Data(buffer[(start + offset + maskLen + len)...])

        switch opcode {
        case 0x0, 0x1: // continuation / text
            fragments.append(contentsOf: payload)
            if fin {
                let text = String(decoding: fragments, as: UTF8.self)
                fragments.removeAll()
                onText?(text)
            }
        case 0x8: // close
            sendFrame(opcode: 0x8, payload: Data(payload.prefix(2)))
            close()
            return false
        case 0x9: sendFrame(opcode: 0xA, payload: Data(payload)) // ping → pong
        default: break // pong / binary ignored
        }
        return true
    }

    func sendText(_ s: String) { sendFrame(opcode: 0x1, payload: Data(s.utf8)) }

    private func sendFrame(opcode: UInt8, payload: Data) {
        guard !closed else { return }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count <= 0xFFFF { frame.append(126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF)) }
        else { frame.append(127); for i in (0..<8).reversed() { frame.append(UInt8((payload.count >> (i * 8)) & 0xFF)) } }
        frame.append(payload)
        nw.send(content: frame, completion: .contentProcessed { _ in })
    }

    func sendRaw(_ s: String) {
        nw.send(content: Data(s.utf8), completion: .contentProcessed { _ in })
    }

    func respond(_ code: Int, _ body: String, contentType: String = "application/json") {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found"][code] ?? "OK"
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(contentType); charset=utf-8\r\nContent-Length: \(data.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n"
        nw.send(content: Data(head.utf8) + data, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}
