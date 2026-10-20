import AppKit
import Carbon.HIToolbox
import RondoKit

/// Display + conversion helpers for `Hotkey` (Carbon virtual key codes, ANSI layout names).
public enum HotkeyFormat {
    /// Canonical macOS order: ⌃⌥⇧⌘.
    static let order: [ModifierKey] = [.control, .option, .shift, .command]

    public static func string(for hotkey: Hotkey) -> String {
        let mods = order.filter(hotkey.modifiers.contains).map(\.symbol).joined()
        return mods + keyName(hotkey.keyCode)
    }

    public static func keyName(_ keyCode: UInt32) -> String {
        if let name = names[Int(keyCode)] { return name }
        return "Key \(keyCode)"
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    public static func carbonModifiers(_ mods: [ModifierKey]) -> UInt32 {
        var mask = 0
        for m in mods {
            switch m {
            case .command: mask |= cmdKey
            case .option: mask |= optionKey
            case .control: mask |= controlKey
            case .shift: mask |= shiftKey
            }
        }
        return UInt32(mask)
    }

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> [ModifierKey] {
        var out: [ModifierKey] = []
        if flags.contains(.control) { out.append(.control) }
        if flags.contains(.option) { out.append(.option) }
        if flags.contains(.shift) { out.append(.shift) }
        if flags.contains(.command) { out.append(.command) }
        return out
    }

    /// A recorded key is usable as a global hotkey if it has ⌃/⌥/⌘ (Shift alone is too easy to hit
    /// while typing), or is a function key.
    public static func isValid(_ hotkey: Hotkey) -> Bool {
        if functionKeys.contains(Int(hotkey.keyCode)) { return true }
        return hotkey.modifiers.contains { $0 != .shift }
    }

    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static let names: [Int: String] = {
        var n: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (i, code) in [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                          kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].enumerated() {
            n[code] = "F\(i + 1)"
        }
        return n
    }()
}

/// Settings edits that keep the modifier → wheel mapping one-to-one.
public enum ModifierMapping {
    /// Assigns `modifier` to `wheel`; the wheel that held `modifier` before takes over `wheel`'s old key.
    public static func assign(_ modifier: ModifierKey, to wheel: WheelKind, in settings: Settings) -> Settings {
        var s = settings
        let old = current(wheel, in: s)
        guard old != modifier else { return s }
        for other in WheelKind.allCases where other != wheel && current(other, in: s) == modifier {
            set(old, for: other, in: &s)
        }
        set(modifier, for: wheel, in: &s)
        return s
    }

    public static func current(_ wheel: WheelKind, in s: Settings) -> ModifierKey {
        switch wheel {
        case .convert: s.convertModifier
        case .tools: s.toolsModifier
        case .actions: s.actionsModifier
        }
    }

    static func set(_ m: ModifierKey, for wheel: WheelKind, in s: inout Settings) {
        switch wheel {
        case .convert: s.convertModifier = m
        case .tools: s.toolsModifier = m
        case .actions: s.actionsModifier = m
        }
    }
}
