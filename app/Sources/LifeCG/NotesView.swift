import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(LifeCGCore)
import LifeCGCore
#endif

/// Speaker notes: control GUI address + PIN, portal sync, what's loaded, cue output.
struct NotesView: View {
    @ObservedObject var model: AppModel
    @State private var portal = ""
    @State private var token = ""
    @State private var accessID = ""
    @State private var accessSecret = ""
    @State private var pin = ""
    @State private var cueName = ""

    private var n: NotesController { model.notes }

    var body: some View {
        let _ = model.notesRevision   // redraw on notes changes
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Control GUI (iPad / laptop / phone on the church network)") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(AppModel.localAddresses(), id: \.self) { ip in
                            let url = "http://\(ip):\(model.settings.port)/control"
                            HStack {
                                Text(url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Button("Open") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                            }
                        }
                        HStack {
                            Text("PIN")
                            TextField("4 digits", text: $pin).frame(width: 80).font(.system(.body, design: .monospaced))
                            Button("Apply") {
                                let p = pin.filter(\.isNumber)
                                if p.count == 4 { model.settings.notesPIN = p } else { pin = model.settings.notesPIN }
                            }
                            Button("New PIN") { model.settings.notesPIN = AppSettings.randomPIN(); pin = model.settings.notesPIN }
                            Text("Changing it signs out everyone who used the PIN.").font(.caption).foregroundColor(.secondary)
                        }
                        Text(model.settings.notesPortalURL.isEmpty
                             ? "Operators can also sign in with their LIFE login once Portal sync is set up below."
                             : "Operators (set in the portal's Admin → Users) can sign in with their LIFE login and choose to be remembered for 30 days.")
                            .font(.caption).foregroundColor(.secondary)
                        let ops = model.server.operatorSessions
                        if !ops.isEmpty {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Signed in: " + ops.map { ($0.name ?? $0.email ?? "?") + ($0.remember ? " (remembered)" : "") }.joined(separator: ", "))
                                    .font(.caption)
                                Button("Sign them out") { model.server.resetNotesSessions(kind: "operator"); model.objectWillChange.send() }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("Loaded notes") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let p = n.loaded {
                            Text("\(p.label ?? p.campusName ?? p.campusId) · \(p.title ?? "Untitled")\(p.speaker.map { " · \($0)" } ?? "")")
                                .font(.headline)
                            Text("Version \(p.version) · \(p.slides.count) slides · theme \(n.themeID)"
                                 + (n.liveIndex.map { " · slide \($0 + 1) live" } ?? " · nothing live"))
                                .font(.caption).foregroundColor(.secondary)
                            if let u = n.pendingUpdate {
                                HStack {
                                    Text("Updated notes available (version \(u.version)).").foregroundColor(.orange)
                                    Button("Load now") { n.applyUpdate() }
                                }
                            }
                        } else {
                            Text("No notes loaded").foregroundColor(.secondary)
                        }
                        HStack {
                            Picker("Service", selection: Binding(get: { n.loaded?.id ?? "" }, set: { if !$0.isEmpty { n.load(serviceID: $0) } })) {
                                if n.loaded == nil { Text("—").tag("") }
                                ForEach(n.serviceList) { s in
                                    Text("\(s.label ?? s.campusId) · \(s.title ?? "") (v\(s.version))").tag(s.id)
                                }
                            }.frame(maxWidth: 420)
                            Button("Import file…") { importFile() }
                        }
                        HStack {
                            Button("Previous") { n.goPrevious() }
                            Button("Next") { n.goNext() }
                            Button("Clear") { n.clear() }
                            Button("Clear All") { n.clearAll() }
                        }.disabled(n.loaded == nil)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("Portal sync") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Portal address, e.g. https://notes.prodapps.life", text: $portal)
                        SecureField("Device token (Admin → Machines in the portal)", text: $token)
                        TextField("Cloudflare Access service token: Client ID", text: $accessID)
                        SecureField("Cloudflare Access service token: Client Secret", text: $accessSecret)
                        HStack {
                            Button("Save") {
                                model.settings.notesPortalURL = portal.trimmingCharacters(in: .whitespaces)
                                model.settings.notesDeviceToken = token.trimmingCharacters(in: .whitespaces)
                                model.settings.notesAccessClientID = accessID.trimmingCharacters(in: .whitespaces)
                                model.settings.notesAccessClientSecret = accessSecret.trimmingCharacters(in: .whitespaces)
                            }
                            Button("Sync now") { n.syncNow() }.disabled(!n.settings.isConfigured)
                            syncStatus
                        }
                    }.padding(4)
                }

                GroupBox("Cue screen output") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Syphon name", text: $cueName).frame(width: 220)
                            Button("Apply") {
                                let v = cueName.trimmingCharacters(in: .whitespaces)
                                if !v.isEmpty { model.settings.cueSyphonName = v }
                            }
                            Label(model.cueHasClients ? "receiving" : "no receivers",
                                  systemImage: model.cueHasClients ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                                .foregroundColor(model.cueHasClients ? .green : .secondary).font(.caption)
                        }
                        HStack(spacing: 24) {
                            Picker("Cue frame rate", selection: $model.settings.cueFrameRate) {
                                ForEach([10.0, 25, 30, 50], id: \.self) { Text(AppModel.fpsLabel($0)).tag($0) }
                            }.frame(width: 220)
                            Picker("Slide dissolve", selection: $model.settings.notesFade) {
                                Text("Cut").tag(0.0); Text("0.2 s").tag(0.2); Text("0.3 s").tag(0.3); Text("0.5 s").tag(0.5)
                            }.frame(width: 200)
                        }
                        if let t = model.notesHub.theme, !NotesRenderer.fontsInstalled(t.theme) {
                            Text("Neuzeit Grotesk isn't installed: notes use Avenir Next instead.").font(.caption).foregroundColor(.orange)
                        }
                    }.padding(4)
                }
            }
        }
        .onAppear {
            portal = model.settings.notesPortalURL; token = model.settings.notesDeviceToken
            accessID = model.settings.notesAccessClientID; accessSecret = model.settings.notesAccessClientSecret
            pin = model.settings.notesPIN; cueName = model.settings.cueSyphonName
        }
    }

    @ViewBuilder private var syncStatus: some View {
        if !n.settings.isConfigured {
            Text("Not set up").font(.caption).foregroundColor(.secondary)
        } else if let e = n.sync.lastError {
            Text(e).font(.caption).foregroundColor(.orange).lineLimit(2)
        } else if let t = n.sync.lastSuccess {
            Text("Synced \(t.formatted(date: .omitted, time: .standard))\(n.sync.deviceName.map { " as \($0)" } ?? "")")
                .font(.caption).foregroundColor(.secondary)
        } else {
            Text("Connecting…").font(.caption).foregroundColor(.secondary)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try n.importPackage(Data(contentsOf: url)) }
        catch { model.addLog("ERROR: import notes: \(error.localizedDescription)") }
    }
}
