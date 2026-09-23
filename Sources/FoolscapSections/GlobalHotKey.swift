import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon hot key: no accessibility permission needed).
public struct HotKeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: NSEvent.ModifierFlags.RawValue
    public var display: String

    public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
        self.display = display
    }

    public var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// ⌃⌥Space
    public static let quickTaskDefault = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.control, .option], display: "⌃⌥Space")

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    public static func display(for event: NSEvent) -> String {
        var s = ""
        let f = event.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→"]
        if let n = names[Int(event.keyCode)] { return s + n }
        return s + (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    public static func load(_ key: String) -> HotKeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    public func save(_ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: key)
    }
}

@MainActor
public final class GlobalHotKey {
    public static let shared = GlobalHotKey()
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var idsByName: [String: UInt32] = [:]
    private var refsByID: [UInt32: EventHotKeyRef] = [:]

    private init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeyID = id.id
            Task { @MainActor in GlobalHotKey.shared.fire(hotKeyID) }
            return noErr
        }, 1, &type, nil, &handlerRef)
    }

    private func fire(_ id: UInt32) { handlers[id]?() }

    /// Register (or replace) the shortcut named `name`. `nil` unregisters it.
    public func register(name: String, combo: HotKeyCombo?, handler: @escaping () -> Void) {
        if let old = idsByName[name], let ref = refsByID[old] {
            UnregisterEventHotKey(ref)
            refsByID[old] = nil; handlers[old] = nil; idsByName[name] = nil
        }
        guard let combo else { return }
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464C5350) /* FLSP */, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refsByID[id] = ref; handlers[id] = handler; idsByName[name] = id
    }
}
