// main.swift - the entry point.
//
// AppKit apps usually hide this behind an @main attribute. Spelled out, it is
// just: make the shared application object, give it a delegate, run the event
// loop. Nothing after app.run() executes until the app quits.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// .accessory = no Dock icon, no app menu, not in Cmd-Tab. Info.plist's
// LSUIElement says the same thing; setting it here as well covers running the
// bare executable from .build/ without the .app wrapper.
app.setActivationPolicy(.accessory)
app.run()
