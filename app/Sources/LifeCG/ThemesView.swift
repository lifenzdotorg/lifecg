import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(LifeCGCore)
import LifeCGCore
#endif

/// Theme library: pick the active look, import a new one from a sample PNG, manage imports.
struct ThemesView: View {
    @ObservedObject var model: AppModel
    @State private var importURL: ImportRequest?
    @State private var dropTargeted = false

    struct ImportRequest: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.themes, id: \.theme.id) { t in
                HStack(spacing: 10) {
                    Image(systemName: model.settings.themeID == t.theme.id ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(model.settings.themeID == t.theme.id ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(t.theme.name).fontWeight(.medium)
                            if t.isBuiltIn { Text("built in").font(.caption2).foregroundColor(.secondary) }
                        }
                        if let n = t.theme.notes { Text(n).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if model.settings.themeID != t.theme.id {
                        Button("Use") { model.selectTheme(t.theme.id) }
                    }
                    if let folder = t.folder {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("theme.json")]) }
                            label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Show the theme's files (theme.json can be edited by hand)")
                    }
                    if !t.isBuiltIn {
                        Button { model.deleteTheme(t.theme.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete this theme")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.selectTheme(t.theme.id) }
            }
            HStack {
                Button { chooseFile() } label: { Label("Import from PNG…", systemImage: "square.and.arrow.down") }
                Button("Reload") { model.reloadThemes() }.help("Re-read themes from disk after editing theme.json")
                Spacer()
            }
            .padding(.top, 4)
            Text("Drop a 1920×1080 PNG of a finished speaker title here (transparent background works best).")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundColor(dropTargeted ? .accentColor : .secondary.opacity(0.5)))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { importURL = ImportRequest(url: url) } }
                    }
                    return true
                }
        }
        .sheet(item: $importURL) { req in
            ThemeImportSheet(model: model, sampleURL: req.url) { importURL = nil }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = "Choose a PNG of a finished speaker title"
        if panel.runModal() == .OK, let url = panel.url { importURL = ImportRequest(url: url) }
    }
}

/// Analyse a sample PNG, show what was detected, preview the result, then save it as a theme.
struct ThemeImportSheet: View {
    @ObservedObject var model: AppModel
    let sampleURL: URL
    var dismiss: () -> Void

    @State private var name = ""
    @State private var titleText = ""
    @State private var designationText = ""
    @State private var titleFont = ""
    @State private var designationFont = ""
    @State private var extraction: ThemeExtraction?
    @State private var preview: CGImage?
    @State private var error: String?
    @State private var sample: CGImage?

    private static let fonts: [String] = (NSFontManager.shared.availableFonts).sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New theme from \(sampleURL.lastPathComponent)").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sample (detected areas outlined)").font(.caption).foregroundColor(.secondary)
                    ZStack {
                        PreviewView(preview: PreviewModel.with(sample.map { NSImage(cgImage: $0, size: .init(width: $0.width, height: $0.height)) }))
                        if let x = extraction { DetectionOverlay(extraction: x) }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Re-drawn with the new theme").font(.caption).foregroundColor(.secondary)
                    PreviewView(preview: PreviewModel.with(preview.map { NSImage(cgImage: $0, size: .init(width: $0.width, height: $0.height)) }))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            .frame(height: 230)

            Form {
                TextField("Theme name", text: $name)
                TextField("Name text shown in the sample", text: $titleText)
                TextField("Designation text shown in the sample (if any)", text: $designationText)
                Picker("Name font", selection: $titleFont) { ForEach(Self.fonts, id: \.self) { Text($0).tag($0) } }
                Picker("Designation font", selection: $designationFont) { ForEach(Self.fonts, id: \.self) { Text($0).tag($0) } }
            }
            Text("Typing the sample's exact text lets the size and letter spacing be matched precisely. Fonts can't be read from pixels, so pick the one the design uses.")
                .font(.caption).foregroundColor(.secondary)

            if let error { Text(error).foregroundColor(.red).font(.callout) }
            if let x = extraction {
                if let m = x.matchScore { Text(String(format: "Match with the sample: %.0f%%", m * 100)).font(.callout) }
                ForEach(x.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange) }
            }

            HStack {
                Button("Analyse") { analyse() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save theme") { save() }.keyboardShortcut(.defaultAction).disabled(extraction == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 820)
        .onAppear(perform: setup)
    }

    private func setup() {
        sample = loadPNG(sampleURL)
        name = sampleURL.deletingPathExtension().lastPathComponent
        let life = Theme.life
        titleFont = life.title.fonts.first { Self.fonts.contains($0) } ?? Self.fonts.first ?? ""
        designationFont = (life.designation?.fonts ?? []).first { Self.fonts.contains($0) } ?? titleFont
        if sample == nil { error = "Couldn't read that file as an image." } else { analyse() }
    }

    private func analyse() {
        guard let sample else { return }
        error = nil
        do {
            let id = ThemeLibrary.makeID(for: name)
            let x = try ThemeExtractor.extract(sample: sample, id: id, name: name.trimmingCharacters(in: .whitespaces),
                                               titleText: titleText.isEmpty ? nil : titleText,
                                               designationText: designationText.isEmpty ? nil : designationText,
                                               titleFonts: [titleFont], designationFonts: [designationFont])
            extraction = x
            let r = GraphicRenderer(theme: LoadedTheme(theme: x.theme, background: x.background, foreground: x.foreground))
            r.render(title: titleText.isEmpty ? "Speaker Name" : titleText,
                     designation: x.theme.designation == nil ? "" : (designationText.isEmpty ? "Designation" : designationText), progress: 1)
            preview = r.makeImage()
        } catch {
            extraction = nil
            preview = nil
            self.error = "Couldn't build a theme from this image: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard var x = extraction, let sample else { return }
        x.theme.name = name.trimmingCharacters(in: .whitespaces)
        x.theme.id = ThemeLibrary.makeID(for: x.theme.name)
        do { try model.saveImportedTheme(x, sample: sample); dismiss() }
        catch { self.error = "Couldn't save the theme: \(error.localizedDescription)" }
    }
}

/// Outlines what the extractor found, over the scaled sample.
struct DetectionOverlay: View {
    let extraction: ThemeExtraction
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / CGFloat(GraphicRenderer.width)
            let boxes: [(CGRect, Color)] = [
                (extraction.titleBar, .green), (extraction.titleInk, .yellow),
            ] + (extraction.designationBar.map { [($0, Color.green)] } ?? [])
              + (extraction.designationInk.map { [($0, Color.yellow)] } ?? [])
            ForEach(Array(boxes.enumerated()), id: \.offset) { _, b in
                Rectangle().stroke(b.1, lineWidth: 1)
                    .frame(width: b.0.width * s, height: b.0.height * s)
                    .position(x: b.0.midX * s, y: b.0.midY * s)
            }
        }
    }
}

extension PreviewModel {
    static func with(_ image: NSImage?) -> PreviewModel { let m = PreviewModel(); m.image = image; return m }
}
