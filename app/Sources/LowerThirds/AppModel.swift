import AppKit
import Combine
import Foundation
import ServiceManagement
#if canImport(LowerThirdsCore)
import LowerThirdsCore
#endif

/// Persisted app settings.
struct AppSettings: Codable, Equatable {
    var port: UInt16 = 9123
    var syphonName = "LowerThirds"
    var offsetX: Double = 0
    var offsetY: Double = 0
    var showDockIcon = true

    static let key = "AppSettings.v1"
    static func load() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// Wires store ⇄ server ⇄ animator ⇄ Syphon, and publishes state for the UI.
final class AppModel: ObservableObject {
    @Published private(set) var state: TitleState
    @Published private(set) var clients: [ControlServer.ClientInfo] = []
    @Published private(set) var preview: NSImage?
    @Published private(set) var log: [String] = []
    @Published private(set) var serverError: String?
    @Published private(set) var syphonHasClients = false
    @Published var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    @Published var launchAtLogin: Bool = false

    let store: TitleStore
    let server: ControlServer
    let renderer: GraphicRenderer
    let animator: GraphicAnimator
    private(set) var syphon: SyphonOutput?
    private var lastPreview = 0.0

    var fontNames: (title: String, designation: String) { renderer.resolvedFontNames() }

    init() {
        let loaded = AppSettings.load()
        settings = loaded
        store = TitleStore(fileURL: TitleStore.defaultFileURL)
        state = store.state
        server = ControlServer(store: store)
        var style = GraphicStyle()
        style.offsetX = loaded.offsetX
        style.offsetY = loaded.offsetY
        let r = GraphicRenderer(style: style)
        renderer = r
        animator = GraphicAnimator(renderer: r)
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }

        syphon = SyphonOutput(name: settings.syphonName)
        if syphon == nil { addLog("ERROR: Metal unavailable — Syphon output disabled") }

        store.onChange = { [weak self] st in
            guard let self else { return }
            self.state = st
            self.server.broadcast(st)
            self.animator.apply(st)
            self.addLog(st.onAir ? "ON AIR: \(st.current!.title)\(st.current!.designation.isEmpty ? "" : " — \(st.current!.designation)")" : "Off air")
        }
        server.onLog = { [weak self] in self?.addLog($0) }
        server.onClientsChanged = { [weak self] in self?.clients = $0 }
        animator.onFrame = { [weak self] r in
            guard let self else { return }
            self.syphon?.publish(r)
            let now = CACurrentMediaTime()
            // Preview at ~20 fps while animating, otherwise only on change.
            if now - self.lastPreview > 0.05 || !self.animator.isAnimating {
                self.lastPreview = now
                if let cg = r.makeImage() {
                    self.preview = NSImage(cgImage: cg, size: NSSize(width: GraphicRenderer.width, height: GraphicRenderer.height))
                }
                let has = self.syphon?.hasClients ?? false
                if has != self.syphonHasClients { self.syphonHasClients = has }
            }
        }

        startServer()
        animator.start()
        addLog("Syphon server: \(settings.syphonName)")
        addLog("Fonts: \(fontNames.title) / \(fontNames.designation)")
    }

    func startServer() {
        do {
            try server.start(port: settings.port)
            serverError = nil
        } catch {
            serverError = "Could not listen on port \(settings.port): \(error.localizedDescription)"
            addLog("ERROR: \(serverError!)")
        }
    }

    // MARK: Operator actions (same paths as remote clients)

    func show(title: String, designation: String) {
        do { try store.show(title: title, designation: designation) } catch { addLog("ERROR: \(error.localizedDescription)") }
    }
    func showRecent(_ e: TitleEntry) { _ = try? store.showRecent(id: e.id) }
    func hide() { store.hide() }
    func toggle() { store.toggle() }
    func remove(_ e: TitleEntry) { store.removeRecent(id: e.id) }
    func clearRecent() { store.clearRecent() }

    func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            addLog("ERROR: launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shutdown() {
        server.stop()
        animator.stop()
        syphon?.stop()
    }

    // MARK: Helpers

    private func settingsChanged(_ old: AppSettings) {
        settings.save()
        if settings.port != old.port { startServer() }
        if settings.syphonName != old.syphonName, !settings.syphonName.isEmpty {
            syphon?.rename(settings.syphonName); addLog("Syphon server renamed: \(settings.syphonName)")
        }
        if settings.offsetX != old.offsetX || settings.offsetY != old.offsetY {
            renderer.style.offsetX = settings.offsetX
            renderer.style.offsetY = settings.offsetY
            animator.redraw()
        }
        if settings.showDockIcon != old.showDockIcon {
            NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        }
    }

    func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// LAN addresses, shown so operators know what to type into Companion.
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(a.ifa_flags) & IFF_LOOPBACK) == 0, (Int32(a.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}
