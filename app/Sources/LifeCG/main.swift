import AppKit
import SwiftUI

/// App entry. AppKit lifecycle (works without Xcode/SwiftPM app templates):
/// a main window plus a menu bar item, so the app can live in the background on the CG Mac.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        model = AppModel()
        NSApp.setActivationPolicy(model.settings.showDockIcon ? .regular : .accessory)
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "LifeCG"
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Previews cost GPU→CPU copies; only make them while the window is actually visible.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                               queue: .main) { [weak self] _ in self?.updatePreviewVisibility() }
        updatePreviewVisibility()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open LifeCG", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Title", action: #selector(hideTitle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LifeCG", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep running (serving Companion + Syphon) when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ note: Notification) { model.shutdown() }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        updatePreviewVisibility()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func hideTitle() { model.hide() }

    func windowWillClose(_ notification: Notification) {
        model.animator.setPreviewEnabled(false)
    }

    private func updatePreviewVisibility() {
        model.animator.setPreviewEnabled(window.isVisible && window.occlusionState.contains(.visible))
    }

    /// Menu bar glyph matching the app icon: the outlined plus with the small solid plus.
    /// Template image, so macOS tints it for light/dark menu bars.
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            func plus(_ r: NSRect, arm: CGFloat) -> NSBezierPath {
                let a = r.width * arm
                let p = NSBezierPath()
                p.move(to: NSPoint(x: r.midX - a / 2, y: r.minY))
                for (x, y) in [(r.midX + a / 2, r.minY), (r.midX + a / 2, r.midY - a / 2), (r.maxX, r.midY - a / 2),
                               (r.maxX, r.midY + a / 2), (r.midX + a / 2, r.midY + a / 2), (r.midX + a / 2, r.maxY),
                               (r.midX - a / 2, r.maxY), (r.midX - a / 2, r.midY + a / 2), (r.minX, r.midY + a / 2),
                               (r.minX, r.midY - a / 2), (r.midX - a / 2, r.midY - a / 2)] {
                    p.line(to: NSPoint(x: x, y: y))
                }
                p.close()
                return p
            }
            NSColor.black.set()
            let outline = plus(NSRect(x: 1.75, y: 4.75, width: 11.5, height: 11.5), arm: 0.44)
            outline.lineWidth = 1.5
            outline.stroke()
            plus(NSRect(x: 12, y: 1, width: 5.5, height: 5.5), arm: 0.42).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "LifeCG"
        return img
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LifeCG", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LifeCG", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LifeCG", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
