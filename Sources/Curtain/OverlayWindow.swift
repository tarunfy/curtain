// OverlayWindow.swift - the full-screen, transparent window the curtain lives in.
//
// It is an NSPanel rather than a plain NSWindow for one reason: the
// .nonactivatingPanel style lets it take mouse events without making Curtain
// the active app, so grabbing the curtain never steals focus from the app you
// were working in.

import AppKit

final class OverlayWindow: NSPanel {
    let curtainView: CurtainView

    init() {
        let screen = OverlayWindow.mainScreen
        curtainView = CurtainView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        // Fully transparent, no title bar, no shadow.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false        // panels hide on deactivate by default
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true

        // Window level is a z-index shared by every app. Normal app windows sit
        // at 0; Finder's desktop icons and the desktop widgets sit at large
        // negative levels. One below normal keeps the curtain under every app
        // window and above the whole desktop. (It used to sit just above the
        // widgets, but everything that far down is composited as part of the
        // desktop, which Space switches and Mission Control show from a cached
        // snapshot that did not include us, so the curtain vanished for a
        // moment after each transition.)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)

        // Show on every Space; .stationary keeps it out of Mission Control the
        // same way the desktop itself is; .ignoresCycle keeps it out of Cmd-`.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // .readOnly (the default) means screenshots and screen sharing see it.
        // Spelled out because the whole app depends on it.
        sharingType = .readOnly

        // Start click-through. cursorMoved() flips this while the cursor is
        // over something grabbable.
        ignoresMouseEvents = true

        contentView = curtainView
    }

    // Never take keyboard focus; we only ever want the mouse.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The display with the menu bar. (NSScreen.main is "the screen with the
    /// key window", which is not the same thing.)
    static var mainScreen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main!
    }

    func fitMainScreen() {
        setFrame(OverlayWindow.mainScreen.frame, display: true)
        curtainView.resetCloth()
    }

    /// Called on every mouse move anywhere on screen. Feeds the cursor to the
    /// cloth and makes the window catch the mouse only while the cursor is
    /// over something grabbable.
    func cursorMoved() {
        let onScreen = NSEvent.mouseLocation
        let inView = curtainView.convert(convertPoint(fromScreen: onScreen), from: nil)
        let overCurtain = curtainView.curtainContains(inView)

        if !curtainView.isDragging, ignoresMouseEvents == overCurtain {   // never drop a drag in progress
            ignoresMouseEvents = !overCurtain
            debugLog("mouse at \(Int(inView.x)),\(Int(inView.y)) -> \(overCurtain ? "over fabric, catching clicks" : "off fabric, passing through")")
        }

        // Is the fabric actually what is under the cursor, or is some app's
        // window covering it there? Asking the window server which window a
        // click would hit answers that for every app, with no permission.
        let topmost = NSWindow.windowNumber(at: onScreen, belowWindowWithWindowNumber: 0)
        curtainView.cursorMoved(to: inView, overFabric: overCurtain && topmost == windowNumber)
    }
}
