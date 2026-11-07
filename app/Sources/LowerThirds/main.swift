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
        window.title = "LowerThirds"
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "LowerThirds")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open LowerThirds", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Title", action: #selector(hideTitle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LowerThirds", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep running (serving Companion + Syphon) when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ note: Notification) { model.shutdown() }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func hideTitle() { model.hide() }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LowerThirds", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LowerThirds", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LowerThirds", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
