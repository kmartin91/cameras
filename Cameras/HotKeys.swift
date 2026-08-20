import Carbon.HIToolbox

enum HotkeyModifiers: String, CaseIterable {
    case controlOption
    case commandOption
    case controlCommand

    var carbon: UInt32 {
        switch self {
        case .controlOption: return UInt32(controlKey | optionKey)
        case .commandOption: return UInt32(cmdKey | optionKey)
        case .controlCommand: return UInt32(controlKey | cmdKey)
        }
    }

    var symbols: String {
        switch self {
        case .controlOption: return "⌃⌥"
        case .commandOption: return "⌘⌥"
        case .controlCommand: return "⌃⌘"
        }
    }
}

enum HotKeys {
    static let freezeIndex = 9
    static let swapIndex = 10
    static let standbyIndex = 11
    static let snapshotIndex = 12
    static let sceneBaseIndex = 13
    static let sceneCount = 4

    private static var callback: ((Int) -> Void)?
    private static var refs: [EventHotKeyRef] = []
    private static var handlerInstalled = false

    private static let baseKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 35, 34, 1]
    private static let sceneKeyCodes: [UInt32] = [18, 19, 20, 21]

    static func install(_ handler: @escaping (Int) -> Void, modifiers: HotkeyModifiers) {
        callback = handler
        if !handlerInstalled {
            handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                HotKeys.callback?(Int(hotKeyID.id))
                return noErr
            }, 1, &spec, nil, nil)
        }
        register(modifiers: modifiers)
    }

    static func register(modifiers: HotkeyModifiers) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        for (index, code) in baseKeyCodes.enumerated() {
            registerKey(code, modifiers.carbon, id: index)
        }
        for (slot, code) in sceneKeyCodes.enumerated() {
            registerKey(code, modifiers.carbon | UInt32(shiftKey), id: sceneBaseIndex + slot)
        }
    }

    private static func registerKey(_ code: UInt32, _ modifiers: UInt32, id: Int) {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: OSType(0x43414D52), id: UInt32(id)), GetEventDispatcherTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}
