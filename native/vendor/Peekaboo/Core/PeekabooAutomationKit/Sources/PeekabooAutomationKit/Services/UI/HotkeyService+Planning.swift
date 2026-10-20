import CoreGraphics
import Foundation
import PeekabooFoundation

extension HotkeyService {
    public nonisolated static func isPasteShortcut(_ keys: String) -> Bool {
        guard let chord = self.shortcut(keys) else { return false }
        return self.isPasteShortcut(primaryKey: chord.primaryKey, flags: chord.flags)
    }

    nonisolated static func isPasteShortcut(primaryKey: String, flags: CGEventFlags) -> Bool {
        primaryKey == "v" && flags == .maskCommand
    }

    /// Whether a chord puts text into the focused field: a character or Space without Command or Control, or a
    /// Command-V paste with any other modifiers.
    public nonisolated static func entersText(_ keys: String) -> Bool {
        guard let chord = try? HotkeyChord(keys: self.parsedKeys(keys)) else { return false }
        let key = chord.plan.primaryKey
        let flags = chord.plan.modifierFlags
        if key == "v", flags.contains(.maskCommand) { return true }
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return false }
        return !self.nonTextKeys.contains(key) && !(key.hasPrefix("f") && Int(key.dropFirst()) != nil)
    }

    /// Keys that edit, move or submit without entering a character.
    private nonisolated static let nonTextKeys: Set<String> = [
        "return", "tab", "escape", "delete", "forwarddelete", "left", "right", "up", "down", "home", "end",
        "pageup", "pagedown", "help", "clear", "capslock", "keypadenter", "keypadclear",
    ]

    public nonisolated static func isSelectAllShortcut(_ keys: String) -> Bool {
        guard let chord = self.shortcut(keys) else { return false }
        return self.isSelectAllShortcut(primaryKey: chord.primaryKey, flags: chord.flags)
    }

    /// The chord's primary key name and modifiers, naming a layout character by the character it types.
    ///
    /// Bridge clients classify a request off the main thread, where no keyboard layout can be read. Resolution
    /// keeps the character as the key's name, so this agrees with the plan the host resolves, and a character the
    /// layout cannot type is still refused there before input.
    nonisolated static func shortcut(_ keys: String) -> (primaryKey: String, flags: CGEventFlags)? {
        guard let parsed = try? self.parsedKeys(keys) else { return nil }
        var flags: CGEventFlags = []
        var primaryKeys: [String] = []
        for key in parsed {
            if let flag = HotkeyKey.modifierFlag(for: key) {
                flags.insert(flag)
            } else {
                primaryKeys.append(key)
            }
        }
        guard primaryKeys.count == 1, let key = primaryKeys.first else { return nil }
        if HotkeyPrimaryKey(key) != nil { return (key, flags) }
        return LayoutCharacter(key).map { ($0.character, flags) }
    }

    nonisolated static func isSelectAllShortcut(primaryKey: String, flags: CGEventFlags) -> Bool {
        primaryKey == "a" && flags == .maskCommand
    }

    func makeHotkeyPlan(_ keys: [String]) throws -> HotkeyPlan {
        try HotkeyChord(keys: keys).plan
    }

    nonisolated static func parsedKeys(_ keys: String) throws -> [String] {
        let parsed = keys
            .components(separatedBy: CharacterSet(charactersIn: ",+").union(.whitespacesAndNewlines))
            .map { HotkeyKey.normalizedName(for: $0) }
            .filter { !$0.isEmpty }
        guard !parsed.isEmpty else { throw PeekabooError.invalidInput("Hotkey string is empty") }
        return parsed
    }

    struct HotkeyPlan: Equatable {
        let primaryKey: String
        let keyCode: CGKeyCode
        let modifierFlags: CGEventFlags
    }

    struct HotkeyChord {
        let plan: HotkeyPlan

        init(keys: [String], layout: @autoclosure () -> KeyboardLayoutTranslator? = .current()) throws {
            var modifierFlags: CGEventFlags = []
            var primaryName: String?

            for rawKey in keys {
                let key = HotkeyKey.normalizedName(for: rawKey)
                if let modifierFlag = HotkeyKey.modifierFlag(for: key) {
                    modifierFlags.insert(modifierFlag)
                    continue
                }

                guard HotkeyPrimaryKey(key) != nil || LayoutCharacter(key) != nil else {
                    throw PeekabooError.invalidInput("Invalid hotkey: \(keys.joined(separator: "+"))")
                }

                if let existing = primaryName {
                    throw PeekabooError.invalidInput("Invalid hotkey: \(existing)+\(key)")
                }

                primaryName = key
            }

            guard let primaryName else {
                throw PeekabooError.invalidInput("Invalid hotkey: \(keys.joined(separator: "+"))")
            }
            // Layout characters resolve after every modifier is known; Command can select another layout.
            let primaryKey = try HotkeyPrimaryKey(primaryName) ?? LayoutCharacter(primaryName)!.resolve(
                flags: modifierFlags, layout: layout())

            self.plan = HotkeyPlan(
                primaryKey: primaryKey.name,
                keyCode: primaryKey.keyCode,
                modifierFlags: modifierFlags)
        }
    }

    enum HotkeyKey {
        static func normalizedName(for rawKey: String) -> String {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return self.aliases[key] ?? key
        }

        static func modifierFlag(for key: String) -> CGEventFlags? {
            switch key {
            case "cmd":
                .maskCommand
            case "shift":
                .maskShift
            case "alt":
                .maskAlternate
            case "ctrl":
                .maskControl
            case "fn":
                .maskSecondaryFn
            default:
                nil
            }
        }

        private static let aliases: [String: String] = [
            "command": "cmd",
            "meta": "cmd",
            "win": "cmd",
            "windows": "cmd",
            "cmdorctrl": "cmd",
            "cmd+ctrl": "cmd",
            "control": "ctrl",
            "option": "alt",
            "opt": "alt",
            "function": "fn",
            "enter": "return",
            "esc": "escape",
            "backspace": "delete",
            "del": "delete",
            "spacebar": "space",
            "page_up": "pageup",
            "page_down": "pagedown",
            "forward_delete": "forwarddelete",
            "arrow_left": "left",
            "arrow_right": "right",
            "arrow_down": "down",
            "arrow_up": "up",
            "left_bracket": "leftbracket",
            "[": "leftbracket",
            "right_bracket": "rightbracket",
            "]": "rightbracket",
            "=": "equal",
            "-": "minus",
            "'": "quote",
            ";": "semicolon",
            "\\": "backslash",
            ",": "comma",
            "/": "slash",
            ".": "period",
            "`": "grave",
            "caps_lock": "capslock",
        ]
    }

    struct HotkeyPrimaryKey {
        let name: String
        let keyCode: CGKeyCode

        init?(_ key: String) {
            guard let keyCode = Self.keyCodes[key] else {
                return nil
            }

            self.name = key
            self.keyCode = keyCode
        }

        init(name: String, keyCode: CGKeyCode) {
            self.name = name
            self.keyCode = keyCode
        }

        /// Keypad keys type digits and operators too, but only their own names select them.
        static let keypadKeyCodes = Set(keyCodes.filter { $0.key.hasPrefix("keypad") }.values)

        private static let keyCodes: [String: CGKeyCode] = [
            "a": 0x00,
            "s": 0x01,
            "d": 0x02,
            "f": 0x03,
            "h": 0x04,
            "g": 0x05,
            "z": 0x06,
            "x": 0x07,
            "c": 0x08,
            "v": 0x09,
            "b": 0x0B,
            "q": 0x0C,
            "w": 0x0D,
            "e": 0x0E,
            "r": 0x0F,
            "y": 0x10,
            "t": 0x11,
            "1": 0x12,
            "2": 0x13,
            "3": 0x14,
            "4": 0x15,
            "6": 0x16,
            "5": 0x17,
            "equal": 0x18,
            "9": 0x19,
            "7": 0x1A,
            "minus": 0x1B,
            "8": 0x1C,
            "0": 0x1D,
            "rightbracket": 0x1E,
            "o": 0x1F,
            "u": 0x20,
            "leftbracket": 0x21,
            "i": 0x22,
            "p": 0x23,
            "return": 0x24,
            "l": 0x25,
            "j": 0x26,
            "quote": 0x27,
            "k": 0x28,
            "semicolon": 0x29,
            "backslash": 0x2A,
            "comma": 0x2B,
            "slash": 0x2C,
            "n": 0x2D,
            "m": 0x2E,
            "period": 0x2F,
            "tab": 0x30,
            "space": 0x31,
            "grave": 0x32,
            "delete": 0x33,
            "escape": 0x35,
            "capslock": 0x39,
            "clear": 0x47,
            "help": 0x72,
            "home": 0x73,
            "pageup": 0x74,
            "forwarddelete": 0x75,
            "end": 0x77,
            "pagedown": 0x79,
            "f1": 0x7A,
            "left": 0x7B,
            "right": 0x7C,
            "down": 0x7D,
            "up": 0x7E,
            "f2": 0x78,
            "f3": 0x63,
            "f4": 0x76,
            "f5": 0x60,
            "f6": 0x61,
            "f7": 0x62,
            "f8": 0x64,
            "f9": 0x65,
            "f10": 0x6D,
            "f11": 0x67,
            "f12": 0x6F,
            "f13": 0x69,
            "f14": 0x6B,
            "f15": 0x71,
            "f16": 0x6A,
            "f17": 0x40,
            "f18": 0x4F,
            "f19": 0x50,
            "f20": 0x5A,
            "keypad0": 0x52,
            "keypad1": 0x53,
            "keypad2": 0x54,
            "keypad3": 0x55,
            "keypad4": 0x56,
            "keypad5": 0x57,
            "keypad6": 0x58,
            "keypad7": 0x59,
            "keypad8": 0x5B,
            "keypad9": 0x5C,
            "keypaddecimal": 0x41,
            "keypadmultiply": 0x43,
            "keypadplus": 0x45,
            "keypadclear": 0x47,
            "keypaddivide": 0x4B,
            "keypadenter": 0x4C,
            "keypadminus": 0x4E,
            "keypadequals": 0x51,
        ]
    }
}
