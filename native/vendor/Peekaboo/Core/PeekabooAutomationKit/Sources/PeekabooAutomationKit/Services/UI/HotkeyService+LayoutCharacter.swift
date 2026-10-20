import Carbon.HIToolbox
import CoreGraphics
import Foundation
import PeekabooFoundation

extension HotkeyService {
    /// A `char:<hex scalar>` hotkey name: the key that types one character on the current keyboard layout.
    ///
    /// Named keys keep their fixed ANSI key codes, which type other characters on other layouts.
    struct LayoutCharacter: Equatable {
        static let prefix = "char:"

        let character: String

        init?(_ name: String) {
            let digits = name.dropFirst(Self.prefix.count)
            guard name.hasPrefix(Self.prefix), (1...6).contains(digits.count),
                  digits.allSatisfy(\.isHexDigit),
                  let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value),
                  Self.isPrintable(scalar)
            else { return nil }
            self.character = String(scalar)
        }

        static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                false
            default:
                !scalar.properties.isWhitespace
            }
        }

        /// Finds the key that types this character with no modifier but Command.
        ///
        /// Command participates because layouts such as "Dvorak - QWERTY ⌘" switch keys while it is held.
        /// A character that needs Shift or Option is refused: adding a modifier the chord did not name would
        /// send different input, and the needed modifier differs between layouts.
        func resolve(flags: CGEventFlags, layout: KeyboardLayoutTranslator?) throws -> HotkeyPrimaryKey {
            guard let layout else {
                throw Self.refusal(
                    "The current keyboard layout has no key map, so no key can be found for \(self.quoted).",
                    hint: "Select a keyboard layout input source, then retry.")
            }
            let base: UInt32 = flags.contains(.maskCommand) ? UInt32(cmdKey) : 0
            if let keyCode = layout.keyCode(typing: self.character, modifiers: base) {
                return HotkeyPrimaryKey(name: self.character, keyCode: keyCode)
            }
            let states: [(UInt32, String)] = [
                (UInt32(shiftKey), "Shift"), (UInt32(optionKey), "Option"),
                (UInt32(shiftKey | optionKey), "Shift and Option"),
            ]
            for (state, modifiers) in states {
                guard let keyCode = layout.keyCode(typing: self.character, modifiers: base | state) else { continue }
                if let unmodified = layout.text(keyCode, base), unmodified.unicodeScalars.allSatisfy(Self.isPrintable) {
                    throw Self.refusal(
                        "On the current keyboard layout, \(self.quoted) needs \(modifiers) with the key that types \"\(unmodified)\".",
                        hint: "Send the key that types \"\(unmodified)\" with \(modifiers) held instead.")
                }
                throw Self.refusal(
                    "On the current keyboard layout, \(self.quoted) needs \(modifiers) with a key that has no character of its own.",
                    hint: "Use text insertion for this character.")
            }
            throw Self.refusal(
                "No key types \(self.quoted) on the current keyboard layout.",
                hint: "Use text insertion for this character, or select a layout that has it.")
        }

        private var quoted: String {
            "\"\(self.character)\""
        }

        private static func refusal(_ message: String, hint: String) -> DesktopActionFailure {
            .preDispatchRefusal(reason: .invalidRequest, message: message, hint: hint)
        }
    }

    /// Reads what keys type from one keyboard layout.
    struct KeyboardLayoutTranslator {
        /// What one key types under a Carbon modifier state; nil when it types nothing or starts a dead key.
        let text: (CGKeyCode, UInt32) -> String?

        func keyCode(typing character: String, modifiers: UInt32) -> CGKeyCode? {
            (0..<128).lazy.map(CGKeyCode.init).first { keyCode in
                !HotkeyPrimaryKey.keypadKeyCodes.contains(keyCode) && self.text(keyCode, modifiers) == character
            }
        }

        /// The current keyboard layout; Text Input Sources is read only on the main thread.
        static func current() -> Self? {
            guard Thread.isMainThread,
                  let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
            let keyboardType = UInt32(LMGetKbdType())
            return Self { keyCode, modifiers in
                data.withUnsafeBytes { bytes in
                    guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                        return nil
                    }
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(
                        layout, keyCode, UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xFF, keyboardType,
                        0, &deadKeyState, characters.count, &length, &characters)
                    guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
                    return String(utf16CodeUnits: characters, count: length)
                }
            }
        }
    }
}
