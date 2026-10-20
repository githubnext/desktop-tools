import AppKit
import ApplicationServices
import DesktopProtocol
import Foundation

// Filling a secure text field, ported from Peekaboo's SecureTextFill (MIT). Whether to fill, and with what secret,
// is the embedder's decision (Hooks.secureTextFill). The secret is typed with key events into the field that has
// keyboard focus and confirmed only by counting the field's mask characters; nothing about it, not even its length,
// is returned, logged or kept.

/// The focused secure field a fill types into, with what its authorization is asked about.
public struct FillField: @unchecked Sendable {
	let element: AXUIElement
	public let applicationName: String?
	public let bundleIdentifier: String?
	/// The host of the field's web page, when it is in a web area whose URL has one.
	public let webHost: String?
}

/// Apps whose password prompts guard the system itself, including those a Keychain read raises.
private let systemPromptBundles: Set<String> = [
	"com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.loginwindow", "com.apple.coreautha",
]
private let maskCharacters: Set<Character> = ["\u{F79A}", "\u{2022}", "\u{25CF}", "*"]

private func refused(_ message: String, _ reason: String) -> Refusal {
	var refusal = Refusal("FILL_REFUSED", message)
	refusal.reason = reason
	return refusal
}

extension Mac {
	/// The exact window's focused secure field, refused before any input when the window is a system authentication
	/// prompt or the focused element isn't secure.
	public static func fillField(_ target: KeyboardTarget) throws -> FillField {
		let pid = target.window.pid
		let app = NSRunningApplication(processIdentifier: pid)
		if let bundle = app?.bundleIdentifier, systemPromptBundles.contains(bundle) {
			throw refused("This is a system authentication prompt, which is filled only by a person. Nothing was typed.", "invalid_request")
		}
		guard let field = fillFocus(pid), secureFocus(field) else {
			throw refused("The focused element is not a secure text field. Nothing was typed.", "invalid_request")
		}
		return FillField(element: field, applicationName: app?.localizedName, bundleIdentifier: app?.bundleIdentifier, webHost: webHost(of: field))
	}

	/// Types an authorized secret into the field. Throws a Refusal before any input, or an Indeterminate once typing
	/// may have started; returns confirmed_change only when the field's mask count matches.
	public static func fill(_ secret: String, into field: FillField, target: KeyboardTarget) throws -> Delivery {
		guard !secret.isEmpty, !secret.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
			throw refused("The password is empty or has control characters, such as newlines or tabs, which key events can't type. Nothing was typed.", "invalid_request")
		}
		// Answering a Keychain prompt or a confirmation may have taken long enough for focus to move.
		guard let current = fillFocus(target.window.pid), CFEqual(current, field.element) else {
			throw refused("The secure field lost keyboard focus while the password was being prepared. Nothing was typed.", "target_unavailable")
		}
		try typeSecret(secret, target: target)
		var matched = false
		for attempt in 0..<15 {
			if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
			guard let shown = AX.string(field.element, kAXValueAttribute), shown.allSatisfy(maskCharacters.contains) else { continue }
			if shown.count == secret.count {
				matched = true
				break
			}
		}
		return matched
			? Delivery(state: .confirmedChange, mechanism: "window_targeted_events", evidence: "verified_change", units: nil)
			: Delivery(state: .dispatchedUnverified, mechanism: "window_targeted_events", evidence: "delivery_accepted", units: nil)
	}

	private static func fillFocus(_ pid: pid_t) -> AXUIElement? {
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, 1)
		return AX.element(AX.value(app, kAXFocusedUIElementAttribute))
	}

	/// The host of the nearest enclosing web area's URL.
	private static func webHost(of element: AXUIElement) -> String? {
		var current = element
		for _ in 0..<64 {
			guard let parent = AX.element(AX.value(current, kAXParentAttribute)) else { return nil }
			current = parent
			guard AX.string(current, kAXRoleAttribute) == "AXWebArea" else { continue }
			let url = AX.value(current, "AXURL")
			return ((url as? URL) ?? (url as? String).flatMap(URL.init(string:)))?.host?.lowercased()
		}
		return nil
	}

	/// Clears the field with Command-A and Delete, then types the secret, checking focus before each key. A failure
	/// never counts the characters sent, which would reveal part of the length.
	private static func typeSecret(_ secret: String, target: KeyboardTarget) throws {
		let source = CGEventSource(stateID: .hidSystemState)
		var sent = 0
		func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, text: [UInt16]? = nil) {
			guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
			event.flags = flags
			if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
			event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.window.pid))
			if let post = skyLightPostToPid { post(target.window.pid, event) } else { event.postToPid(target.window.pid) }
			sent += 1
		}
		func check() throws {
			do { _ = try requireKeyboardFocus(target) } catch {
				guard sent > 0 else {
					throw refused("The secure field could not take typed input. Nothing was typed.", "operation_unsupported")
				}
				// Command is released before giving up, so it is never left held.
				post(0x37, false, [])
				throw Indeterminate(
					Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: nil),
					"Typing the password stopped partway.", hint: "Inspect the window; clear the field before filling it again."
				)
			}
		}
		try check()
		post(0x37, true, .maskCommand)
		usleep(1000)
		post(0x00, true, .maskCommand)
		usleep(1000)
		post(0x00, false, .maskCommand)
		usleep(1000)
		post(0x37, false, [])
		Thread.sleep(forTimeInterval: 0.05)
		try check()
		post(0x33, true, [])
		usleep(1000)
		post(0x33, false, [])
		Thread.sleep(forTimeInterval: 0.05)
		for character in secret {
			try check()
			let units = Array(String(character).utf16)
			post(0, true, [], text: units)
			usleep(1000)
			post(0, false, [], text: units)
			usleep(2000)
		}
	}
}
