import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey via the Carbon event API (no Accessibility permission required).
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let me = GlobalHotKey.instances[hk.id] {
                DispatchQueue.main.async { me.action() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x52444f54) /* 'RDOT' */, id: id)
        let reg = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard reg == noErr else {
            if let h = handlerRef { RemoveEventHandler(h) }
            return nil
        }
        GlobalHotKey.instances[id] = self
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        ref = nil
        handlerRef = nil
        GlobalHotKey.instances[id] = nil
    }

    deinit { unregister() }

    static func make(_ choice: AppSettings.HotKeyChoice, action: @escaping () -> Void) -> GlobalHotKey? {
        let r = UInt32(kVK_ANSI_R)
        switch choice {
        case .optCmdR: return GlobalHotKey(keyCode: r, modifiers: UInt32(optionKey | cmdKey), action: action)
        case .ctrlOptCmdR: return GlobalHotKey(keyCode: r, modifiers: UInt32(controlKey | optionKey | cmdKey), action: action)
        case .ctrlOptR: return GlobalHotKey(keyCode: r, modifiers: UInt32(controlKey | optionKey), action: action)
        case .none: return nil
        }
    }
}
