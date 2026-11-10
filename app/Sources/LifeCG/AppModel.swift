import AppKit
import CoreText
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
    /// Active theme id (see ThemeLibrary).
    var themeID = "life"

    // Speaker notes
    var notesPortalURL = ""
    var notesDeviceToken = ""
    var notesAccessClientID = ""
    var notesAccessClientSecret = ""
    /// 4-digit PIN for the LAN control GUI (http://<this Mac>:<port>/control).
    var notesPIN = AppSettings.randomPIN()
    var cueSyphonName = "LifeCG Cue"
    /// The cue screen only shows still text, so a low rate is plenty.
    var cueFrameRate: Double = 25
    /// Dissolve between notes slides (0 = cut).
    var notesFade: Double = 0.3

    static func randomPIN() -> String { String(format: "%04d", Int.random(in: 0...9999)) }

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
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? d.themeID
        notesPortalURL = try c.decodeIfPresent(String.self, forKey: .notesPortalURL) ?? d.notesPortalURL
        notesDeviceToken = try c.decodeIfPresent(String.self, forKey: .notesDeviceToken) ?? d.notesDeviceToken
        notesAccessClientID = try c.decodeIfPresent(String.self, forKey: .notesAccessClientID) ?? d.notesAccessClientID
        notesAccessClientSecret = try c.decodeIfPresent(String.self, forKey: .notesAccessClientSecret) ?? d.notesAccessClientSecret
        notesPIN = try c.decodeIfPresent(String.self, forKey: .notesPIN) ?? d.notesPIN
        cueSyphonName = try c.decodeIfPresent(String.self, forKey: .cueSyphonName) ?? d.cueSyphonName
        cueFrameRate = try c.decodeIfPresent(Double.self, forKey: .cueFrameRate) ?? d.cueFrameRate
        notesFade = try c.decodeIfPresent(Double.self, forKey: .notesFade) ?? d.notesFade
    }

    var notesSettings: NotesController.Settings {
        var n = NotesController.Settings()
        n.portalURL = notesPortalURL.trimmingCharacters(in: .whitespaces)
        n.deviceToken = notesDeviceToken.trimmingCharacters(in: .whitespaces)
        n.accessClientID = notesAccessClientID.trimmingCharacters(in: .whitespaces)
        n.accessClientSecret = notesAccessClientSecret.trimmingCharacters(in: .whitespaces)
        return n
    }

    static let key = "AppSettings.v1"
    static func load() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// Live preview image, kept separate from AppModel so a new frame only redraws the
/// preview, not the whole window.
final class PreviewModel: ObservableObject {
    @Published var image: NSImage?
}

/// Wires store ⇄ server ⇄ animator ⇄ Syphon, and publishes state for the UI.
final class AppModel: ObservableObject {
    @Published private(set) var state: TitleState
    @Published private(set) var clients: [ControlServer.ClientInfo] = []
    let preview = PreviewModel()
    @Published private(set) var log: [String] = []
    @Published private(set) var serverError: String?
    @Published private(set) var syphonHasClients = false
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var themes: [LoadedTheme] = []
    /// Bumped whenever speaker-notes state changes (the Notes tab observes it).
    @Published private(set) var notesRevision = 0
    @Published private(set) var cueHasClients = false
    @Published var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    @Published var launchAtLogin: Bool = false

    let store: TitleStore
    let server: ControlServer
    let renderer: GraphicRenderer
    let animator: GraphicAnimator
    private(set) var syphon: SyphonOutput?
    private(set) var cue: CueOutput?
    let notes: NotesController
    let notesHub: NotesHub
    private var statusTimer: Timer?
    private var titleWasOnAir = false

    /// The theme currently on output.
    var activeTheme: LoadedTheme { themes.first { $0.theme.id == settings.themeID } ?? themes[0] }

    /// Fonts the active theme resolves to on this Mac, and whether its preferred fonts are installed.
    var fontNames: (title: String, designation: String, preferredInstalled: Bool) {
        let t = activeTheme.theme
        func resolve(_ names: [String]) -> (String, Bool) {
            for n in names where (CTFontCopyPostScriptName(CTFontCreateWithName(n as CFString, 12, nil)) as String) == n {
                return (n, n == names.first)
            }
            return ("system font", false)
        }
        let a = resolve(t.title.fonts), b = resolve((t.designation ?? t.title).fonts)
        return (a.0, b.0, a.1 && b.1)
    }

    init() {
        let loaded = AppSettings.load()
        settings = loaded
        store = TitleStore(fileURL: TitleStore.defaultFileURL)
        state = store.state
        server = ControlServer(store: store)
        let library = ThemeLibrary.all()
        themes = library
        let active = library.first { $0.theme.id == loaded.themeID } ?? library[0]
        let r = GraphicRenderer(theme: active)
        r.offset = CGPoint(x: loaded.offsetX, y: loaded.offsetY)
        renderer = r
        // Every Mac that runs macOS 13 has Metal; without it there is nothing to output.
        guard let anim = GraphicAnimator(renderer: r) else { fatalError("LifeCG needs Metal (GPU) support") }
        animator = anim
        // Speaker notes
        notes = NotesController(settings: loaded.notesSettings)
        notesHub = NotesHub(controller: notes, animator: anim)
        animator.setConfig(Self.animatorConfig(loaded))
        store.defaultAutoClearSeconds = loaded.autoClearSeconds
        store.setThemes(active: active.theme.id, all: library.map { ThemeInfo(id: $0.theme.id, name: $0.theme.name) })
        state = store.state
        if #available(macOS 13.0, *) { launchAtLogin = SMAppService.mainApp.status == .enabled }

        syphon = SyphonOutput(name: settings.syphonName, device: anim.compositor.device)
        if syphon == nil { addLog("ERROR: Syphon server could not start") }

        cue = CueOutput(name: loaded.cueSyphonName, compositor: anim.compositor, frameRate: loaded.cueFrameRate)
        if cue == nil { addLog("ERROR: cue Syphon server could not start") }
        notes.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        settings.save()   // persists a newly generated PIN

        store.onChange = { [weak self] st in
            guard let self else { return }
            self.state = st
            self.server.broadcast(st)
            self.animator.apply(st)
            // A title going on air replaces the notes slide (one replaces the other).
            if st.onAir && !self.titleWasOnAir { self.notes.clear() }
            self.titleWasOnAir = st.onAir
            self.server.broadcastNotes()
            self.addLog(st.onAir ? "ON AIR: \(st.current!.title)\(st.current!.designation.isEmpty ? "" : " — \(st.current!.designation)")" : "Off air")
        }
        server.onLog = { [weak self] in self?.addLog($0) }
        server.onClientsChanged = { [weak self] in self?.clients = $0 }
        server.onSetTheme = { [weak self] id in self?.selectTheme(id) ?? false }
        server.onHide = { [weak self] in self?.notes.clear() }
        server.onClearAll = { [weak self] in self?.notes.clearAll() }
        server.notesHub = notesHub
        server.notesPIN = { [weak self] in self?.settings.notesPIN ?? "" }
        server.notesSessionFile = NotesController.defaultCacheDir.deletingLastPathComponent().appendingPathComponent("control-sessions.json")
        notes.onLog = { [weak self] in self?.addLog($0) }
        notesHub.titleOnAir = { [weak self] in self?.store.state.onAir ?? false }
        notesHub.onNotesWentLive = { [weak self] in
            guard let self, self.store.state.onAir else { return }
            self.store.hide()
        }
        notesHub.onCue = { [weak self] c in self?.cue?.show(c) }
        notesHub.onStateChange = { [weak self] in
            guard let self else { return }
            self.server.broadcastNotes()
            self.notesRevision &+= 1
        }
        let syphon = self.syphon
        animator.onFrame = { tex, cb in syphon?.publish(tex, on: cb) }   // render queue
        animator.onPreview = { [weak self] img in                         // main queue
            self?.preview.image = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        }

        startServer()
        animator.start()
        notesHub.apply()
        cue?.show(notesHub.cueContent)
        notes.startSync()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fps = self.animator.measuredFPS()
            if abs(fps - self.measuredFPS) > 0.05 { self.measuredFPS = fps }
            let has = self.syphon?.hasClients ?? false
            if has != self.syphonHasClients { self.syphonHasClients = has }
            let cueHas = self.cue?.hasClients ?? false
            if cueHas != self.cueHasClients { self.cueHasClients = cueHas }
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

    // MARK: Themes

    /// Switch the output to theme `id` (from the UI or a Companion). False if unknown.
    @discardableResult
    func selectTheme(_ id: String) -> Bool {
        guard themes.contains(where: { $0.theme.id == id }) else { return false }
        if settings.themeID != id { settings.themeID = id }   // → settingsChanged → applyActiveTheme
        return true
    }

    private func applyActiveTheme() {
        let t = activeTheme
        animator.setTheme(t)
        store.setThemes(active: t.theme.id, all: themes.map { ThemeInfo(id: $0.theme.id, name: $0.theme.name) })
        addLog("Theme: \(t.theme.name)")
        objectWillChange.send()
    }

    /// Re-read themes from disk (after an import, delete or hand edit).
    func reloadThemes() {
        themes = ThemeLibrary.all()
        if !themes.contains(where: { $0.theme.id == settings.themeID }) { settings.themeID = themes[0].theme.id }
        applyActiveTheme()
    }

    /// Save an imported theme and switch to it.
    func saveImportedTheme(_ x: ThemeExtraction, sample: CGImage) throws {
        try ThemeLibrary.save(x.theme, background: x.background, foreground: x.foreground, extras: ["sample.png": sample])
        themes = ThemeLibrary.all()
        addLog("Imported theme: \(x.theme.name)")
        selectTheme(x.theme.id)
        applyActiveTheme()
    }

    func deleteTheme(_ id: String) {
        guard let t = themes.first(where: { $0.theme.id == id }), !t.isBuiltIn else { return }
        do { try ThemeLibrary.delete(id: id); addLog("Deleted theme: \(t.theme.name)") }
        catch { addLog("ERROR: delete theme: \(error.localizedDescription)") }
        reloadThemes()
    }

    static func animatorConfig(_ s: AppSettings) -> GraphicAnimator.Config {
        var c = GraphicAnimator.Config()
        c.inTransition = s.transitionIn
        c.outTransition = s.transitionOut
        c.frameRate = s.frameRate
        c.offset = CGPoint(x: s.offsetX, y: s.offsetY)
        c.notesFade = s.notesFade
        return c
    }

    func shutdown() {
        statusTimer?.invalidate()
        server.stop()
        animator.stop()
        syphon?.stop()
        cue?.stop()
        notes.stopSync()
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
        if settings.themeID != old.themeID { applyActiveTheme() }
        if settings.notesSettings != old.notesSettings { notes.settings = settings.notesSettings }
        if settings.notesPIN != old.notesPIN { server.resetNotesSessions(kind: "pin"); addLog("Control GUI PIN changed") }
        if settings.cueSyphonName != old.cueSyphonName, !settings.cueSyphonName.isEmpty { cue?.rename(settings.cueSyphonName) }
        if settings.cueFrameRate != old.cueFrameRate { cue?.setFrameRate(settings.cueFrameRate) }
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
