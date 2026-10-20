import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DesktopProtocol
import Foundation

// Background keys and typing, ported from Peekaboo's HotkeyService, TypeService and BackgroundInputDriver
// (MIT). Key events go to the window's process only. Nothing makes the window key: the app's own focused
// window and element must already be in the exact window, which is checked before every event.

/// Virtual key codes by this contract's key names (ANSI).
private let namedKeys: [String: CGKeyCode] = [
	"enter": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33, "escape": 0x35, "delete": 0x75,
	"help": 0x72, "home": 0x73, "pageup": 0x74, "end": 0x77, "pagedown": 0x79,
	"left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
	"f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65,
	"f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40,
	"f18": 0x4F, "f19": 0x50, "f20": 0x5A,
	"keypad0": 0x52, "keypad1": 0x53, "keypad2": 0x54, "keypad3": 0x55, "keypad4": 0x56, "keypad5": 0x57,
	"keypad6": 0x58, "keypad7": 0x59, "keypad8": 0x5B, "keypad9": 0x5C, "keypaddecimal": 0x41,
	"keypadmultiply": 0x43, "keypadplus": 0x45, "keypadclear": 0x47, "keypaddivide": 0x4B, "keypadenter": 0x4C,
	"keypadminus": 0x4E, "keypadequals": 0x51,
]

/// Modifier key codes and flags, pressed in this order and released in reverse.
private let modifierKeys: [(name: String, code: CGKeyCode, flag: CGEventFlags)] = [
	("command", 0x37, .maskCommand), ("shift", 0x38, .maskShift), ("option", 0x3A, .maskAlternate), ("control", 0x3B, .maskControl),
]

public let keyModifierNames: Set<String> = Set(modifierKeys.map(\.name))

/// One key with its modifiers, resolved to a key code before any input.
public struct Chord: Sendable {
	public let key: String
	public let code: CGKeyCode
	public let modifiers: [String]
	/// Whether the chord types into the receiver: a character or Space without Command or Control, or Command-V.
	public let entersText: Bool
	public let isCharacter: Bool
}

/// The window keys go to and the control the snapshot saw focused there, if any.
public struct KeyboardTarget: Sendable {
	public let window: ClickWindow
	/// Role, frame and identifier of the snapshot's focused element; the live focus must still match it.
	public let focusedRole: String?
	public let focusedFrame: CGRect?
	public init(window: ClickWindow, focusedRole: String?, focusedFrame: CGRect?) {
		self.window = window
		self.focusedRole = focusedRole
		self.focusedFrame = focusedFrame
	}
}

extension Mac {
	/// Resolves a named key, or the one character a key types on the current layout, refusing characters that
	/// need Shift or Option so the model sends the modifier explicitly.
	public static func chord(_ key: String, modifiers: [String]) throws -> Chord {
		let entersByModifiers = !modifiers.contains("command") && !modifiers.contains("control")
		if let code = namedKeys[key] {
			return Chord(key: key, code: code, modifiers: modifiers, entersText: key == "space" && entersByModifiers, isCharacter: false)
		}
		guard key.unicodeScalars.count == 1 else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Choose a named key or the one printable character a key types, such as , or a.")
		}
		let base: UInt32 = modifiers.contains("command") ? UInt32(cmdKey >> 8) : 0
		let quoted = "\"\(key)\""
		let layout = try onMain { try Layout() }
		if let code = layout.code(typing: key, modifiers: base) {
			let paste = modifiers == ["command"] && key.lowercased() == "v"
			return Chord(key: key, code: code, modifiers: modifiers, entersText: entersByModifiers || paste, isCharacter: true)
		}
		for (state, names) in [(UInt32(shiftKey >> 8), "Shift"), (UInt32(optionKey >> 8), "Option"), (UInt32((shiftKey | optionKey) >> 8), "Shift and Option")] {
			guard let code = layout.code(typing: key, modifiers: base | state) else { continue }
			if let plain = layout.text(code, modifiers: base), !plain.isEmpty, plain.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.properties.generalCategory != .control }) {
				throw Refusal("DESKTOP_ACTION_FAILED", "On the current keyboard layout, \(quoted) needs \(names) with the key that types \"\(plain)\". Send the key that types \"\(plain)\" with \(names) held instead.")
			}
			throw Refusal("DESKTOP_ACTION_FAILED", "On the current keyboard layout, \(quoted) needs \(names) with a key that has no character of its own. Use text insertion for this character.")
		}
		throw Refusal("DESKTOP_ACTION_FAILED", "No key types \(quoted) on the current keyboard layout. Use text insertion for this character, or select a layout that has it.")
	}

	/// The app's focused element, which must be in the exact window, inside its bounds, in the app's own key
	/// window, with no sheet over it, and the same control the snapshot saw focused.
	public static func requireKeyboardFocus(_ target: KeyboardTarget) throws -> AXUIElement {
		let window = target.window
		try window.check()
		let app = AXUIElementCreateApplication(window.pid)
		AXUIElementSetMessagingTimeout(app, 0.2)
		let refusal = Refusal("FOCUS_NOT_IN_WINDOW", "Exact-window keyboard focus is not on the target window at dispatch. Click the control to focus it, inspect again, and retry; keys never bring a background window forward.")
		guard let focusedWindow = AX.element(AX.value(app, kAXFocusedWindowAttribute)), AX.windowID(focusedWindow) == window.windowID,
		      let focused = AX.element(AX.value(app, kAXFocusedUIElementAttribute))
		else { throw refusal }
		if let sheets = AX.value(focusedWindow, "AXSheets") as? [AXUIElement], !sheets.isEmpty { throw refusal }
		AXUIElementSetMessagingTimeout(focused, 0.2)
		if let owner = AX.element(AX.value(focused, kAXWindowAttribute)), AX.windowID(owner) != window.windowID { throw refusal }
		if let frame = AX.frame(focused), frame.width > 0, !window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) { throw refusal }
		if let role = target.focusedRole {
			guard AX.string(focused, kAXRoleAttribute) == role, let expected = target.focusedFrame, let frame = AX.frame(focused),
			      abs(frame.minX - expected.minX) <= 1, abs(frame.minY - expected.minY) <= 1,
			      abs(frame.width - expected.width) <= 1, abs(frame.height - expected.height) <= 1
			else { throw Refusal("FOCUS_CHANGED", "Keyboard focus moved off the control the snapshot saw focused. Inspect the window again.") }
		}
		return focused
	}

	/// Whether the focused element is a password field, which only a password fill may type into.
	static func secureFocus(_ focused: AXUIElement) -> Bool {
		AX.string(focused, kAXRoleAttribute) == "AXSecureTextField" || AX.string(focused, kAXSubroleAttribute) == "AXSecureTextField"
	}

	/// One chord to the exact window's keyboard focus: modifiers down in order, the key, modifiers up in reverse.
	public static func press(_ chord: Chord, target: KeyboardTarget) throws -> Delivery {
		let focused = try requireKeyboardFocus(target)
		if chord.entersText, secureFocus(focused) {
			throw Refusal("SECURE_FIELD_REQUIRES_FILL", "A password field has keyboard focus, so keys that type characters aren't sent. Use desktop_fill_password.")
		}
		// AppKit ignores a background Command-A key event, so a native text field selects all through Accessibility.
		if chord.modifiers == ["command"], chord.key.lowercased() == "a", !isWebField(focused),
		   let value = AX.string(focused, kAXValueAttribute), settable(focused, kAXSelectedTextRangeAttribute)
		{
			var range = CFRange(location: 0, length: (value as NSString).length)
			if let all = AXValueCreate(.cfRange, &range),
			   AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, all) == .success
			{
				return .accepted("accessibility_value")
			}
		}
		let held = modifierKeys.filter { chord.modifiers.contains($0.name) }
		var flags: CGEventFlags = []
		var plan: [(CGKeyCode, Bool, CGEventFlags)] = []
		for modifier in held {
			flags.insert(modifier.flag)
			plan.append((modifier.code, true, flags))
		}
		plan.append((chord.code, true, flags))
		plan.append((chord.code, false, flags))
		for modifier in held.reversed() {
			flags.remove(modifier.flag)
			plan.append((modifier.code, false, flags))
		}
		return try postKeys(plan, target: target, check: { try requireKeyboardFocus(target) })
	}

	/// Literal text as Unicode key events to the exact window's focused control, for web fields whose page
	/// ignores an Accessibility value write. Clears the field first with Command-A and Delete.
	public static func typeKeys(_ text: String, target: KeyboardTarget) throws -> Delivery {
		let focused = try requireKeyboardFocus(target)
		if secureFocus(focused) {
			throw Refusal("SECURE_FIELD_REQUIRES_FILL", "A password field has keyboard focus. Use desktop_fill_password.")
		}
		if IsSecureEventInputEnabled() {
			throw Refusal("SECURE_INPUT_ACTIVE", "Secure keyboard entry is on, so typed keys can't reach the window.")
		}
		var plan: [(CGKeyCode, Bool, CGEventFlags)] = [(0x37, true, .maskCommand), (0x00, true, .maskCommand), (0x00, false, .maskCommand), (0x37, false, [])]
		var delivery = try postKeys(plan, target: target, check: { try requireKeyboardFocus(target) })
		guard delivery.outcome == "completed" else { return delivery }
		Thread.sleep(forTimeInterval: 0.05)
		plan = [(0x33, true, []), (0x33, false, [])]
		delivery = try postKeys(plan, target: target, check: { try requireKeyboardFocus(target) }, alreadySent: 4)
		guard delivery.outcome == "completed" else { return delivery }
		Thread.sleep(forTimeInterval: 0.05)
		var sent = 6
		let source = CGEventSource(stateID: .hidSystemState)
		for character in text {
			do { try requireKeyboardFocus(target) } catch {
				return Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: sent)
			}
			let units = Array(String(character).utf16)
			for down in [true, false] {
				guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
				event.flags = []
				event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
				post(event, pid: target.window.pid)
				sent += 1
				if down { usleep(1000) }
			}
			usleep(2000)
		}
		// Read back what the page now holds; an exact match confirms the typing.
		let deadline = ContinuousClock.now + .milliseconds(250)
		while ContinuousClock.now < deadline {
			if AX.string(focused, kAXValueAttribute) == text {
				return Delivery(state: .confirmedChange, mechanism: "window_targeted_events", evidence: "verified_change", units: sent)
			}
			Thread.sleep(forTimeInterval: 0.02)
		}
		return Delivery(state: .dispatchedUnverified, mechanism: "window_targeted_events", evidence: "delivery_accepted", units: sent)
	}

	private static func postKeys(_ plan: [(CGKeyCode, Bool, CGEventFlags)], target: KeyboardTarget, check: () throws -> AXUIElement, alreadySent: Int = 0) throws -> Delivery {
		let source = CGEventSource(stateID: .hidSystemState)
		var posted = 0
		for (index, (code, down, flags)) in plan.enumerated() {
			if index > 0 { usleep(1000) }
			// Key-ups always follow their key-downs, so a key is never left held in the app.
			if down {
				do { _ = try check() } catch {
					if posted + alreadySent == 0 { throw error }
					releaseHeld(plan[..<index], pid: target.window.pid, source: source)
					return Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: alreadySent + posted)
				}
			}
			guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
			event.flags = flags
			post(event, pid: target.window.pid)
			posted += 1
		}
		usleep(10_000)
		return Delivery(state: .dispatchedUnverified, mechanism: "window_targeted_events", evidence: "delivery_accepted", units: nil)
	}

	private static func releaseHeld(_ sent: ArraySlice<(CGKeyCode, Bool, CGEventFlags)>, pid: pid_t, source: CGEventSource?) {
		var held: [CGKeyCode] = []
		for (code, down, _) in sent { if down { held.append(code) } else { held.removeAll { $0 == code } } }
		for code in held.reversed() {
			guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
			post(event, pid: pid)
		}
	}

	/// Key events carry only the target process; SkyLight's post reaches more apps than the public one.
	private static func post(_ event: CGEvent, pid: pid_t) {
		event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
		if let post = skyLightPostToPid { post(pid, event) } else { event.postToPid(pid) }
	}

	// MARK: Accessibility value

	/// Whether the field is inside a web page, whose scripts ignore an Accessibility value write. A field whose
	/// ancestry can't be proven native counts as web.
	public static func isWebField(_ element: AXUIElement) -> Bool {
		var current = element
		let deadline = ContinuousClock.now + .milliseconds(250)
		for _ in 0..<32 where ContinuousClock.now < deadline {
			guard let parent = AX.element(AX.value(current, kAXParentAttribute)) else { return true }
			switch AX.string(parent, kAXRoleAttribute) {
			case "AXWebArea": return true
			case "AXWindow", "AXApplication": return false
			default: current = parent
			}
		}
		return true
	}

	/// Replaces a native field's whole value through Accessibility and reads it back.
	public static func setText(_ element: AXUIElement, _ text: String, window: ClickWindow) throws -> Delivery {
		AXUIElementSetMessagingTimeout(element, 1)
		if AX.string(element, kAXValueAttribute) == text {
			return Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil)
		}
		try window.check()
		let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
		switch error {
		case .success: break
		case .attributeUnsupported, .actionUnsupported:
			throw Refusal("VALUE_NOT_SETTABLE", "The element's text can't be set through Accessibility.")
		case .invalidUIElement:
			throw Refusal("ELEMENT_NOT_FOUND", "The element is gone from the window. Inspect it again.")
		default:
			return Delivery(state: .indeterminate, mechanism: "accessibility_value", evidence: "completion_unknown", units: 1)
		}
		let deadline = ContinuousClock.now + .milliseconds(250)
		for _ in 0..<14 where ContinuousClock.now < deadline {
			if AX.string(element, kAXValueAttribute) == text {
				return Delivery(state: .confirmedChange, mechanism: "accessibility_value", evidence: "verified_change", units: 1)
			}
			Thread.sleep(forTimeInterval: 0.02)
		}
		return Delivery(state: .indeterminate, mechanism: "accessibility_value", evidence: "completion_unknown", units: 1)
	}
}

/// The current keyboard layout's key map, read on the main thread as Text Input Sources require.
private struct Layout {
	let data: Data
	let keyboardType = UInt32(LMGetKbdType())

	init() throws {
		guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
		      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
		else { throw Refusal("DESKTOP_ACTION_FAILED", "The current keyboard layout has no key map. Select a keyboard layout input source, then retry.") }
		data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
	}

	func text(_ code: CGKeyCode, modifiers: UInt32) -> String? {
		data.withUnsafeBytes { bytes -> String? in
			guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
			var dead: UInt32 = 0
			var length = 0
			var chars = [UniChar](repeating: 0, count: 8)
			let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType,
			                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
			return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
		}
	}

	/// The first non-keypad key that types the character with exactly these modifiers.
	func code(typing character: String, modifiers: UInt32) -> CGKeyCode? {
		let keypad: Set<CGKeyCode> = [0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]
		for code in CGKeyCode(0)..<128 where !keypad.contains(code) {
			if text(code, modifiers: modifiers) == character { return code }
		}
		return nil
	}
}

private func onMain<T>(_ work: () throws -> T) throws -> T {
	if Thread.isMainThread { return try work() }
	return try DispatchQueue.main.sync(execute: work)
}

let skyLightPostToPid: (@convention(c) (pid_t, CGEvent) -> Void)? = {
	_ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
	return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLEventPostToPid").map {
		unsafeBitCast($0, to: (@convention(c) (pid_t, CGEvent) -> Void).self)
	}
}()
