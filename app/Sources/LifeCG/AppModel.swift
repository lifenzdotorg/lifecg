import AppKit
import Combine
import Foundation
import ServiceManagement
#if canImport(LifeCGCore)
import LifeCGCore
#endif

/// Persisted app settings.
struct AppSettings: Codable, Equatable {
    var port: UInt16 = 9123
    var syphonName = "LifeCG"
    var offsetX: Double = 0
    var offsetY: Double = 0
    var showDockIcon = true
    var transitionIn: Transition = .slideBoxFadeText
    var transitionOut: Transition = .slideBoxFadeText
    /// Output frame rate. LIFE runs everything at 1080p50.
    var frameRate: Double = 50
    /// Used when Companion's "Auto clear" tickbox is on.
    var autoClearSeconds: Double = 8

    static let frameRates: [Double] = [25, 29.97, 30, 50, 59.94, 60]

    init() {}

    // Tolerant decoding: settings saved by an older build (missing newer keys) keep their values.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        syphonName = try c.decodeIfPresent(String.self, forKey: .syphonName) ?? d.syphonName
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? d.offsetX
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? d.offsetY
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? d.showDockIcon
        transitionIn = (try? c.decodeIfPresent(Transition.self, forKey: .transitionIn)) ?? d.transitionIn
        transitionOut = (try? c.decodeIfPresent(Transition.self, forKey: .transitionOut)) ?? d.transitionOut
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate) ?? d.frameRate
        autoClearSeconds = try c.decodeIfPresent(Double.self, forKey: .autoClearSeconds) ?? d.autoClearSeconds
    }

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
    @Published private(set) var measuredFPS: Double = 0
    @Published var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    @Published var launchAtLogin: Bool = false

    let store: TitleStore
    let server: ControlServer
    let renderer: GraphicRenderer
    let animator: GraphicAnimator
    private(set) var syphon: SyphonOutput?
    private var statusTimer: Timer?

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
        // Every Mac that runs macOS 13 has Metal; without it there is nothing to output.
        guard let anim = GraphicAnimator(renderer: r) else { fatalError("LifeCG needs Metal (GPU) support") }
        animator = anim
        animator.setConfig(Self.animatorConfig(loaded))
        store.defaultAutoClearSeconds = loaded.autoClearSeconds
        state = store.state
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }

        syphon = SyphonOutput(name: settings.syphonName, device: anim.compositor.device)
        if syphon == nil { addLog("ERROR: Syphon server could not start") }

        store.onChange = { [weak self] st in
            guard let self else { return }
            self.state = st
            self.server.broadcast(st)
            self.animator.apply(st)
            self.addLog(st.onAir ? "ON AIR: \(st.current!.title)\(st.current!.designation.isEmpty ? "" : " — \(st.current!.designation)")" : "Off air")
        }
        server.onLog = { [weak self] in self?.addLog($0) }
        server.onClientsChanged = { [weak self] in self?.clients = $0 }
        let syphon = self.syphon
        animator.onFrame = { tex, cb in syphon?.publish(tex, on: cb) }   // render queue
        animator.onPreview = { [weak self] img in                         // main queue
            self?.preview = NSImage(cgImage: img, size: NSSize(width: GraphicRenderer.width, height: GraphicRenderer.height))
        }

        startServer()
        animator.start()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fps = self.animator.measuredFPS()
            if abs(fps - self.measuredFPS) > 0.05 { self.measuredFPS = fps }
            let has = self.syphon?.hasClients ?? false
            if has != self.syphonHasClients { self.syphonHasClients = has }
        }
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

    static func animatorConfig(_ s: AppSettings) -> GraphicAnimator.Config {
        var c = GraphicAnimator.Config()
        c.inTransition = s.transitionIn
        c.outTransition = s.transitionOut
        c.frameRate = s.frameRate
        c.offset = CGPoint(x: s.offsetX, y: s.offsetY)
        return c
    }

    func shutdown() {
        statusTimer?.invalidate()
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
        let newConfig = Self.animatorConfig(settings)
        if newConfig != Self.animatorConfig(old) { animator.setConfig(newConfig) }
        if settings.transitionIn != old.transitionIn || settings.transitionOut != old.transitionOut {
            addLog("Transitions: on = \(settings.transitionIn.label), off = \(settings.transitionOut.label)")
        }
        if settings.frameRate != old.frameRate { addLog("Output frame rate: \(Self.fpsLabel(settings.frameRate))") }
        if settings.autoClearSeconds != old.autoClearSeconds {
            store.defaultAutoClearSeconds = settings.autoClearSeconds
            addLog("Auto clear time: \(Int(settings.autoClearSeconds)) s")
        }
        if settings.showDockIcon != old.showDockIcon {
            NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        }
    }

    static func fpsLabel(_ f: Double) -> String {
        f == f.rounded() ? "\(Int(f)) fps" : String(format: "%.2f fps", f)
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
