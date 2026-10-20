import AppKit
import CoreGraphics
import Foundation

/// A media, volume or brightness key, which macOS delivers as a system-defined event rather than a key code.
public enum SystemDefinedKey: String, Codable, Sendable, CaseIterable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown
    case playPause
    case next
    case previous
    case keyboardBrightnessUp
    case keyboardBrightnessDown

    /// The `NX_KEYTYPE_*` value from IOKit's `ev_keymap.h`.
    var keyType: Int {
        switch self {
        case .volumeUp: 0
        case .volumeDown: 1
        case .brightnessUp: 2
        case .brightnessDown: 3
        case .mute: 7
        case .playPause: 16
        case .next: 17
        case .previous: 18
        case .keyboardBrightnessUp: 21
        case .keyboardBrightnessDown: 22
        }
    }
}

enum SystemDefinedKeyEvents {
    /// The `NX_SUBTYPE_AUX_CONTROL_BUTTONS` subtype that carries special keys.
    private static let auxControlButtons: Int16 = 8

    /// Posts one press and release to the HID tap; the system, not a window, decides what the key does.
    static func post(_ key: SystemDefinedKey) throws {
        // Build both events before posting either, so a failure never leaves the key held down.
        let events = try [true, false].map { down in
            let state = down ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: self.auxControlButtons,
                data1: (key.keyType << 16) | (state << 8),
                data2: -1)?.cgEvent
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Could not create the \(key.rawValue) system key event")
            }
            return event
        }
        for event in events {
            event.post(tap: .cghidEventTap)
        }
    }
}
