import AppKit
import ServiceManagement
import SwiftUI

// Hosts to monitor. ssh aliases resolved via ~/.ssh/config or DNS.
let hostConfigs: [HostConfig] = [
    HostConfig("deepmonster"),
    HostConfig("deepmonster2"),
    HostConfig("deepzilla"),
    HostConfig("spark"),
]

private let frameDefaultsKey = "panelFrame"
private let zoomDefaultsKey = "zoomLevel"

/// A borderless NSPanel won't accept key events by default, so the ⌘+/⌘−/⌘0 zoom
/// shortcuts inside the SwiftUI view would never fire. Allowing it to become key
/// (it stays a non-activating floating panel) lets those shortcuts work once the
/// widget has been clicked.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let store = MonitorStore(hostConfigs)
    var panel: NSPanel!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        installStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    // MARK: - Panel

    private func buildPanel() {
        let root = ContentView().environmentObject(store)
        // A hosting *controller* makes the panel track the SwiftUI fitting size — it
        // grows/shrinks to fit every GPU row automatically, keeping top-left fixed.
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]

        // Borderless so the content reaches the top edge and the window can sit flush
        // under the menu bar; a titled NSPanel adds an invisible title-bar strip.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentViewController = hosting
        self.panel = panel

        restoreOrPlacePanel()
        panel.orderFrontRegardless()
    }

    /// Restore the saved frame if any of it is still on a connected screen; otherwise
    /// place top-right of the main display.
    private func restoreOrPlacePanel() {
        if let str = UserDefaults.standard.string(forKey: frameDefaultsKey) {
            let rect = NSRectFromString(str)
            if rect.width > 100, rect.height > 50, isFrameOnAnyScreen(rect) {
                panel.setFrame(rect, display: true)
                return
            }
        }
        positionTopRight(panel)
    }

    /// True when at least 30% of the frame's area overlaps a screen's visible area —
    /// guards against a saved position on a now-disconnected monitor.
    private func isFrameOnAnyScreen(_ rect: NSRect) -> Bool {
        let area = rect.width * rect.height
        guard area > 0 else { return false }
        for screen in NSScreen.screens {
            let inter = screen.visibleFrame.intersection(rect)
            if !inter.isNull && inter.width * inter.height >= area * 0.3 {
                return true
            }
        }
        return false
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16,
                                     y: vf.maxY - size.height - 16))
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameDefaultsKey)
    }

    /// Live monitor-config change — if the panel ended up off-screen (e.g. you closed
    /// the laptop or unplugged the monitor it lived on), nudge it back into view.
    @objc private func screensChanged() {
        guard let panel else { return }
        if !isFrameOnAnyScreen(panel.frame) {
            positionTopRight(panel)
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "vibemon")
                ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: "vibemon")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "vibemon"
        }

        let menu = NSMenu()
        menu.delegate = self

        let toggle = NSMenuItem(title: "Hide vibemon",
                                action: #selector(toggleShow),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        // Zoom lives here rather than as on-panel chrome — rarely touched, so out of the way.
        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        zoomIn.target = self
        menu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOut.target = self
        menu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Reset Zoom", action: #selector(zoomReset), keyEquivalent: "0")
        zoomReset.target = self
        menu.addItem(zoomReset)

        menu.addItem(NSMenuItem.separator())

        // Login Items only makes sense when running as a proper .app bundle.
        if Bundle.main.bundleIdentifier != nil {
            let loginItem = NSMenuItem(title: "Open at Login",
                                       action: #selector(toggleLoginItem),
                                       keyEquivalent: "")
            loginItem.target = self
            menu.addItem(loginItem)
            menu.addItem(NSMenuItem.separator())
        }

        let quit = NSMenuItem(title: "Quit vibemon",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Refresh dynamic state right before the menu pops.
    func menuWillOpen(_ menu: NSMenu) {
        if let toggle = menu.items.first(where: { $0.action == #selector(toggleShow) }) {
            toggle.title = panel.isVisible ? "Hide vibemon" : "Show vibemon"
        }
        if let item = menu.items.first(where: { $0.action == #selector(toggleLoginItem) }) {
            item.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func toggleShow() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            // Make sure it lands somewhere visible if a monitor disappeared while hidden.
            if !isFrameOnAnyScreen(panel.frame) { positionTopRight(panel) }
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Zoom (shared with the SwiftUI view via UserDefaults / @AppStorage)

    private var currentZoom: Double {
        (UserDefaults.standard.object(forKey: zoomDefaultsKey) as? Double) ?? zoomDefault
    }
    private func applyZoom(_ v: Double) {
        UserDefaults.standard.set(clampZoom(v), forKey: zoomDefaultsKey)
    }
    @objc private func zoomIn()    { applyZoom(currentZoom + 0.1) }
    @objc private func zoomOut()   { applyZoom(currentZoom - 0.1) }
    @objc private func zoomReset() { applyZoom(zoomDefault) }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Open at Login"
            alert.runModal()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, lives as a floating utility
    app.run()
}
