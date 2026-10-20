import AppKit
import Carbon
import CoreGraphics
import Foundation

// Ported from Peekaboo's SystemDefinedKeyEvents, HotkeyService and InputSourceSelection (MIT).

/// The media, volume and brightness keys, by their `NX_KEYTYPE_*` value from IOKit's `ev_keymap.h`.
public let systemDefinedKeys: [String: Int] = [
	"volume_up": 0, "volume_down": 1, "brightness_up": 2, "brightness_down": 3, "mute": 7,
	"play_pause": 16, "next_track": 17, "previous_track": 18, "keyboard_brightness_up": 21, "keyboard_brightness_down": 22,
]

private let modifierFlags: [String: CGEventFlags] = [
	"command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl,
]

extension Mac {
	public static var sessionLocked: Bool {
		(CGSessionCopyCurrentDictionary() as NSDictionary?)?["CGSSessionScreenIsLocked"] as? Bool == true
	}

	/// Posts one press and release of a media key to the HID tap; the system, not a window, decides what it does.
	public static func postSystemDefinedKey(_ keyType: Int) throws -> Delivery {
		// Build both events before posting either, so a failure never leaves the key held down.
		let events = try [true, false].map { down in
			let state = down ? 0xA : 0xB
			guard let event = NSEvent.otherEvent(
				with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
				timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (keyType << 16) | (state << 8), data2: -1
			)?.cgEvent else { throw ToolFailure("Could not create the system key event") }
			return event
		}
		for event in events { event.post(tap: .cghidEventTap) }
		return globalDelivery()
	}

	/// Posts one chord as the keyboard would, to whatever is frontmost.
	public static func postGlobalChord(_ chord: Chord) throws -> Delivery {
		let flags = chord.modifiers.reduce(into: CGEventFlags()) { $0.insert(modifierFlags[$1]!) }
		let source = CGEventSource(stateID: .hidSystemState)
		guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.code, keyDown: true),
		      let up = CGEvent(keyboardEventSource: source, virtualKey: chord.code, keyDown: false)
		else { throw ToolFailure("Failed to create keyboard events") }
		down.flags = flags
		up.flags = flags
		down.post(tap: .cghidEventTap)
		up.post(tap: .cghidEventTap)
		return globalDelivery()
	}

	private static func globalDelivery() -> Delivery {
		var delivery = Delivery(state: .dispatchedUnverified, mechanism: "global_events", evidence: "delivery_accepted", units: 1)
		delivery.mode = "foreground"
		return delivery
	}
}

/// An error whose message is the whole description, as Peekaboo's envelopes print.
public struct ToolFailure: Error, CustomStringConvertible {
	public let description: String
	public init(_ description: String) { self.description = description }
}

/// One enabled keyboard input source.
public struct InputSource: Sendable {
	public let id: String
	public let name: String?
	/// keyboard_layout, input_mode (one mode of an input method, such as Hiragana) or input_method.
	public let kind: String
	public let languages: [String]
	public let selected: Bool
}

/// Text Input Sources are read and changed on the main thread, where the run loop delivers their changes.
@MainActor
public enum InputSources {
	/// The enabled keyboard input sources the user can switch to, as the input menu offers them.
	public static func selectable() -> [InputSource] {
		raw().compactMap { source in
			guard let id: String = property(source, kTISPropertyInputSourceID) else { return nil }
			return InputSource(
				id: id, name: property(source, kTISPropertyLocalizedName), kind: kind(source),
				languages: property(source, kTISPropertyInputSourceLanguages) ?? [],
				selected: property(source, kTISPropertyInputSourceIsSelected) ?? false
			)
		}
	}

	public static func current() -> String? {
		TISCopyCurrentKeyboardInputSource().flatMap { property($0.takeRetainedValue(), kTISPropertyInputSourceID) }
	}

	public static func layout() -> String? {
		TISCopyCurrentKeyboardLayoutInputSource().flatMap { property($0.takeRetainedValue(), kTISPropertyInputSourceID) }
	}

	public static func select(_ id: String) throws {
		guard let source = raw().first(where: { property($0, kTISPropertyInputSourceID) == id }) else {
			throw ToolFailure("No enabled input source has the ID \(id)")
		}
		let status = TISSelectInputSource(source)
		guard status == noErr else { throw ToolFailure("macOS refused to select the input source (status \(status))") }
	}

	private static func raw() -> [TISInputSource] {
		let filter = [kTISPropertyInputSourceCategory!: kTISCategoryKeyboardInputSource!, kTISPropertyInputSourceIsSelectCapable!: true] as CFDictionary
		return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
	}

	private static func kind(_ source: TISInputSource) -> String {
		let type: String? = property(source, kTISPropertyInputSourceType)
		if type == kTISTypeKeyboardLayout as String { return "keyboard_layout" }
		if type == kTISTypeKeyboardInputMode as String { return "input_mode" }
		return "input_method"
	}

	private static func property<Value>(_ source: TISInputSource, _ key: CFString) -> Value? {
		guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
		return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? Value
	}
}
