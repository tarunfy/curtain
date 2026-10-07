// HotKey.swift - a system-wide keyboard shortcut.
//
// macOS offers two ways to hear a key press while another app is active.
// Event monitors (NSEvent.addGlobalMonitorForEvents) need the user to grant
// Accessibility access. The older Carbon hot-key API does not: the system
// delivers only the one registered combination, and only to us, so nothing
// about it can spy on typing. It is decades old but still fully supported.

import Carbon.HIToolbox

final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// keyCode is a virtual key code (kVK_ANSI_C = 8, kVK_ANSI_K = 40 ...);
    /// modifiers are Carbon masks (cmdKey, optionKey, controlKey, shiftKey).
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        // Carbon calls a plain C function pointer, which cannot capture
        // `self`, so `self` is smuggled through the userData pointer.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue().action()
            return noErr
        }, 1, &eventType, userData, &handlerRef)

        let id = EventHotKeyID(signature: 0x4352_544E /* 'CRTN' */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        debugLog(status == noErr ? "hot key registered" : "hot key registration failed: \(status)")
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
