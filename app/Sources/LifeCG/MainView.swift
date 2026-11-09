import AppKit
import SwiftUI
#if canImport(LifeCGCore)
import LifeCGCore
#endif

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var title = ""
    @State private var designation = ""
    @State private var tab = 0

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                statusBar
                PreviewView(preview: model.preview)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                manualEntry
                Picker("", selection: $tab) {
                    Text("Connections").tag(0)
                    Text("Settings").tag(1)
                    Text("Themes").tag(3)
                    Text("Log").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Group {
                    switch tab {
                    case 0: ConnectionsView(model: model)
                    case 1: SettingsView(model: model)
                    case 3: ThemesView(model: model)
                    default: LogView(lines: model.log)
                    }
                }
                .frame(minHeight: 150, maxHeight: .infinity, alignment: .top)
            }
            .padding(16)
            .frame(minWidth: 560)

            RecentView(model: model) { e in
                title = e.title; designation = e.designation
            }
            .frame(minWidth: 260, idealWidth: 300)
        }
        .frame(minWidth: 880, minHeight: 720)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(model.state.onAir ? "ON AIR" : "OFF AIR")
                .font(.system(size: 12, weight: .heavy))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(model.state.onAir ? Color.red : Color.gray.opacity(0.35))
                .foregroundColor(.white)
                .clipShape(Capsule())
            if let c = model.state.current {
                Text(c.designation.isEmpty ? c.title : "\(c.title) — \(c.designation)")
                    .font(.headline).lineLimit(1)
                if let at = model.state.autoClearAt {
                    Label("auto-clear \(at.formatted(date: .omitted, time: .standard))", systemImage: "timer")
                        .font(.caption).foregroundColor(.orange)
                }
            }
            Spacer()
            Text("\(AppModel.fpsLabel(model.settings.frameRate)) · measured \(String(format: "%.1f", model.measuredFPS))")
                .font(.caption).foregroundColor(abs(model.measuredFPS - model.settings.frameRate) < 1 ? .secondary : .orange)
            Label(model.syphonHasClients ? "Syphon: receiving" : "Syphon: no receivers",
                  systemImage: model.syphonHasClients ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundColor(model.syphonHasClients ? .green : .secondary)
                .font(.caption)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Title (name)", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField("Designation (optional)", text: $designation)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button {
                    model.show(title: title, designation: designation)
                } label: { Label("Show", systemImage: "play.fill").frame(minWidth: 80) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    model.hide()
                } label: { Label("Hide", systemImage: "stop.fill").frame(minWidth: 80) }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Clear fields") { title = ""; designation = "" }
                Spacer()
                if let err = model.serverError {
                    Text(err).foregroundColor(.red).font(.caption).lineLimit(2)
                }
            }
        }
    }
}

/// Checkerboard behind the transparent frame so alpha is visible.
struct PreviewView: View {
    @ObservedObject var preview: PreviewModel
    var body: some View {
        let image = preview.image
        return
        ZStack {
            Canvas { ctx, size in
                let s: CGFloat = 12
                for y in stride(from: 0, to: size.height, by: s) {
                    for x in stride(from: 0, to: size.width, by: s) {
                        let dark = (Int(x / s) + Int(y / s)) % 2 == 0
                        ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)),
                                 with: .color(dark ? Color(white: 0.32) : Color(white: 0.42)))
                    }
                }
            }
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            }
        }
    }
}

struct RecentView: View {
    @ObservedObject var model: AppModel
    var onEdit: (TitleEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Titles").font(.headline)
                Text("\(model.state.recent.count)/\(TitleStore.maxRecent)").foregroundColor(.secondary).font(.caption)
                Spacer()
                Button("Clear") { model.clearRecent() }
                    .disabled(model.state.recent.isEmpty)
            }
            .padding(12)
            Divider()
            List {
                ForEach(model.state.recent, id: \.id) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).fontWeight(.semibold)
                            if !e.designation.isEmpty { Text(e.designation).font(.caption).foregroundColor(.secondary) }
                        }
                        Spacer()
                        if model.state.current?.id == e.id {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                        }
                        Button { model.showRecent(e) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless).help("Show")
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.showRecent(e) }
                    .contextMenu {
                        Button("Show") { model.showRecent(e) }
                        Button("Edit in fields") { onEdit(e) }
                        Divider()
                        Button("Remove") { model.remove(e) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Point Companion at one of:").font(.caption).foregroundColor(.secondary)
            ForEach(AppModel.localAddresses(), id: \.self) { ip in
                Text("\(ip)  port \(String(model.settings.port))").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Divider().padding(.vertical, 4)
            if model.clients.isEmpty {
                Text("No control clients connected").foregroundColor(.secondary)
            } else {
                ForEach(model.clients, id: \.id) { c in
                    HStack {
                        Image(systemName: "circle.fill").foregroundColor(.green).font(.system(size: 7))
                        Text(c.name).fontWeight(.medium)
                        Text(c.kind).foregroundColor(.secondary).font(.caption)
                        Spacer()
                        Text(c.address).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var portText = ""
    @State private var syphonName = ""

    var body: some View {
        Form {
            HStack {
                TextField("Control port", text: $portText).frame(width: 220)
                Button("Apply") { if let p = UInt16(portText), p > 0 { model.settings.port = p } }
            }
            HStack {
                TextField("Syphon server name", text: $syphonName).frame(width: 300)
                Button("Apply") {
                    let n = syphonName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { model.settings.syphonName = n }
                }
            }
            HStack {
                Stepper("Nudge X: \(Int(model.settings.offsetX)) px", value: $model.settings.offsetX, in: -400...400, step: 2)
                Stepper("Nudge Y: \(Int(model.settings.offsetY)) px", value: $model.settings.offsetY, in: -400...400, step: 2)
                Button("Reset") { model.settings.offsetX = 0; model.settings.offsetY = 0 }
            }
            HStack(spacing: 24) {
                Picker("Animate on", selection: $model.settings.transitionIn) {
                    ForEach(Transition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 280)
                Picker("Animate off", selection: $model.settings.transitionOut) {
                    ForEach(Transition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 280)
            }
            HStack(spacing: 24) {
                Picker("Output frame rate", selection: $model.settings.frameRate) {
                    ForEach(AppSettings.frameRates, id: \.self) { Text(AppModel.fpsLabel($0)).tag($0) }
                }
                .frame(width: 280)
                Stepper("Auto clear after: \(Int(model.settings.autoClearSeconds)) s",
                        value: $model.settings.autoClearSeconds, in: 1...120, step: 1)
            }
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Toggle("Show Dock icon (menu bar icon is always shown)", isOn: $model.settings.showDockIcon)
            Text("Fonts in use: \(model.fontNames.title) / \(model.fontNames.designation)\(model.fontNames.preferredInstalled ? "" : " (fallback: install the theme's font)")")
                .font(.caption).foregroundColor(model.fontNames.preferredInstalled ? .secondary : .orange)
        }
        .onAppear { portText = String(model.settings.port); syphonName = model.settings.syphonName }
    }
}

struct LogView: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _ in proxy.scrollTo(lines.count - 1) }
        }
    }
}
