// AppDelegate.swift - app lifecycle: the menu bar item, the overlay window,
// the keyboard shortcut, and the system-wide mouse watcher that decides when
// clicks reach the curtain.

import AppKit
import CurtainCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var fabricMenu: NSMenu?
    private var muteItem: NSMenuItem?
    private var overlay: OverlayWindow?
    private var hotKey: HotKey?
    private var mouseMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        let window = OverlayWindow()
        // orderFront() only works for the active app, and an accessory app is
        // almost never active. orderFrontRegardless() shows it anyway.
        window.orderFrontRegardless()
        window.curtainView.onStateChange = { [weak self] in self?.refreshStatus() }
        overlay = window
        refreshStatus()

        hotKey = HotKey(keyCode: Tuning.shortcutKeyCode, modifiers: Tuning.shortcutModifiers) { [weak self] in
            self?.toggleCurtain()
        }

        // The window ignores mouse events by default so the desktop underneath
        // stays clickable. We watch the cursor system-wide and switch that flag
        // off only while the cursor is over fabric. Global monitors receive mouse
        // movement from other apps with no permission prompt (only keyboard
        // monitoring needs Accessibility). They are read-only: we see the event,
        // we cannot change or swallow it.
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak window] _ in
            window?.cursorMoved()
        }
        // While the cursor is over our own window the events come to us instead
        // of to "other apps", so a local monitor covers that half.
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak window] event in
            window?.cursorMoved()
            return event
        }
        mouseMonitors = [global, local].compactMap { $0 }

        // Resolution or display changes: re-cover the screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak window] _ in
            window?.fitMainScreen()
        }

        // After a Space switch or Mission Control, and whenever the window
        // becomes visible again, draw a frame straight away even if the cloth
        // is asleep, so there is never a blank moment.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak window] _ in
            window?.orderFrontRegardless()
            window?.curtainView.redraw()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak window] _ in
            if window?.occlusionState.contains(.visible) == true { window?.curtainView.redraw() }
        }

        if UserDefaults.standard.bool(forKey: "muted") { toggleMute() }
    }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button, NSImage(systemSymbolName: "curtains.closed", accessibilityDescription: nil) == nil {
            button.title = "Curtain"   // very old SF Symbols: fall back to text
        }

        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "Close Curtain", action: #selector(toggleCurtain), keyEquivalent: "c")
        // The key equivalent shown here is only a reminder; it would only fire
        // while Curtain is the active app, which it never is. The HotKey does
        // the real work.
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        // Fabric submenu, one item per look in Tuning.looks.
        let fabric = NSMenu(title: "Fabric")
        for (index, look) in Tuning.looks.enumerated() {
            let entry = NSMenuItem(title: look.name, action: #selector(selectFabric(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            fabric.addItem(entry)
        }
        let fabricItem = NSMenuItem(title: "Fabric", action: nil, keyEquivalent: "")
        fabricItem.submenu = fabric
        menu.addItem(fabricItem)
        fabricMenu = fabric

        let mute = NSMenuItem(title: "Mute Sounds", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        menu.addItem(mute)
        muteItem = mute

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Curtain",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        toggleItem = toggle
        statusItem = item
    }

    @objc private func toggleCurtain() {
        overlay?.curtainView.toggle()
    }

    @objc private func selectFabric(_ sender: NSMenuItem) {
        guard let view = overlay?.curtainView, Tuning.looks.indices.contains(sender.tag) else { return }
        view.look = Tuning.looks[sender.tag]
        UserDefaults.standard.set(view.look.name, forKey: "look")
        refreshStatus()
    }

    @objc private func toggleMute() {
        guard let sound = overlay?.curtainView.sound else { return }
        sound.muted.toggle()
        UserDefaults.standard.set(sound.muted, forKey: "muted")
        refreshStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
    }

    /// Menu title and icon follow the curtain: "Close" while it is open, and
    /// the icon shows where it is heading.
    private func refreshStatus() {
        let closed = overlay?.curtainView.isClosed ?? false
        toggleItem?.title = closed ? "Open Curtain" : "Close Curtain"
        statusItem?.button?.image = NSImage(systemSymbolName: closed ? "curtains.closed" : "curtains.open",
                                            accessibilityDescription: "Curtain")
        let current = overlay?.curtainView.look.name
        for item in fabricMenu?.items ?? [] { item.state = item.title == current ? .on : .off }
        muteItem?.state = overlay?.curtainView.sound.muted == true ? .on : .off
    }
}
