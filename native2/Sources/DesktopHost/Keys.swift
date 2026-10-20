import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

private let semanticShortcuts = ["w": "desktop_close", "q": "desktop_quit", "h": "desktop_hide", "m": "desktop_minimize"]
/// Lets the receiver handle one key, such as moving focus, before the next.
private let keySequenceGap: UInt32 = 30_000
private let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

extension Snapshot {
	/// The one element the inspection saw focused, which keys go to when it still has focus.
	var focused: Element? {
		let focused = elements.values.filter { $0.attributes["isFocused"] == "true" }
		return focused.count == 1 ? focused[0] : nil
	}
}

extension Tools {
	static func modifierList(_ value: JSON?) throws -> [String] {
		guard let value else { return [] }
		guard let list = value.array?.compactMap(\.string), list.count == value.array?.count, list.count <= 4,
		      Set(list).count == list.count, list.allSatisfy(keyModifierNames.contains)
		else { throw ToolError("Use each of command, control, option, and shift at most once.") }
		return list
	}

	static func key(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		guard (arguments["key"] == nil) != (arguments["keys"] == nil) else { throw ToolError("Choose one key, or a sequence of keys.") }
		var requested: [(key: String, modifiers: [String])] = []
		// Node's order: each key, then its modifiers.
		func chord(_ value: JSON) throws -> (key: String, modifiers: [String]) {
			guard let key = value["key"]?.string, isDesktopKey(key) else { throw ToolError("Choose a named key or one printable character.") }
			return (key, try modifierList(value["modifiers"]))
		}
		if let keys = arguments["keys"] {
			guard let list = keys.array, (1...16).contains(list.count), arguments["modifiers"] == nil, arguments["repeat"] == nil else {
				throw ToolError("Give 1 to 16 keys, each with its own modifiers, and no repeat.")
			}
			for value in list {
				guard let names = value.keys, names.allSatisfy({ $0 == "key" || $0 == "modifiers" }) else {
					throw ToolError("Give each key as an object with key and optional modifiers.")
				}
				requested.append(try chord(value))
			}
		} else {
			let count = arguments["repeat"]?.int ?? 1
			guard arguments["repeat"] == nil || (1...32).contains(count) && arguments["repeat"]?.int != nil else { throw ToolError("Repeat a key 1 to 32 times.") }
			requested = Array(repeating: try chord(arguments), count: count)
		}
		let sequence = arguments["keys"] != nil || requested.count > 1
		let wanted = requested
		let semantic = wanted.lazy.filter { $0.modifiers == ["command"] }.compactMap { chord in
			semanticShortcuts[chord.key].map { tool in
				Refusal(
					"DESKTOP_ACTION_FAILED", "Command-\(chord.key.uppercased()) can't be verified when sent to a background window, so it isn't sent.",
					hint: "Use \(tool) instead; it reports whether it took effect."
				)
			}
		}.first
		let send = {
			await act("key", snapshotID: snapshotID, element: nil, early: semantic) { snapshot, _ in
				let chords = try wanted.map { try Mac.chord($0.key, modifiers: $0.modifiers) }
				let window = window(snapshot)
				if !sequence {
					let focused = snapshot.focused
					var delivery = try Mac.press(chords[0], target: KeyboardTarget(window: window, focusedRole: focused?.attributes["role"], focusedFrame: focused?.frame))
					delivery.fields = [("receiver", JSON(focused == nil ? "window_focus" : "observed_control"))]
					return delivery
				}
				// A sequence goes to whatever has focus in the window, which each key may move.
				let target = KeyboardTarget(window: window, focusedRole: nil, focusedFrame: nil)
				var sent = 0
				for (index, chord) in chords.enumerated() {
					if index > 0 { usleep(keySequenceGap) }
					do {
						let delivery = try Mac.press(chord, target: target)
						guard delivery.outcome == "completed" else { throw Refusal("KEY_SEQUENCE_STOPPED", "A key's delivery couldn't be confirmed.") }
						sent += 1
					} catch let refusal as Refusal where sent > 0 {
						var stopped = Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: sent)
						stopped.fields = [
							("receiver", "window_focus"), ("keys_requested", JSON(chords.count)), ("keys_sent", JSON(sent)),
							("error", .object([("code", "KEY_SEQUENCE_STOPPED"), ("message", JSON("The sequence stopped after \(sent) of \(chords.count) keys: \(refusal.message)"))])),
						]
						return stopped
					}
				}
				var delivery = Delivery(state: .dispatchedUnverified, mechanism: "window_targeted_events", evidence: "delivery_accepted", units: nil)
				delivery.fields = [("receiver", "window_focus"), ("keys_requested", JSON(chords.count)), ("keys_sent", JSON(sent))]
				return delivery
			}
		}
		if let expect = try expectation(arguments) { return try await expectAfter(expect) { await send() } }
		return await send()
	}

	static func type(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		guard let element = arguments["element"]?.string, (1...256).contains(element.utf16.count) else {
			throw ToolError("Choose an element ID from the inspected snapshot.")
		}
		guard let text = arguments["text"]?.string, text.utf16.count <= 8192 else {
			throw ToolError("Replacement text must contain at most 8192 UTF-16 code units.")
		}
		return await act("type", snapshotID: snapshotID, element: element, precheck: { _, target in
			let attributes = target!.attributes
			if attributes["role"] == "AXSecureTextField" || attributes["subrole"] == "AXSecureTextField" {
				throw Refusal(
					"SECURE_FIELD_REQUIRES_FILL",
					"This is a secure text field, such as a password field, and text is never typed, set or selected in it. Nothing was sent.",
					hint: "Fill password fields with desktop_fill_password, from a Keychain item or with the user's approval."
				)
			}
		}) { snapshot, target in
			let target = target!
			let window = window(snapshot)
			let role = target.attributes["role"] ?? ""
			guard textRoles.contains(role) || target.attributes["subrole"] == "AXSearchField", Mac.isWebField(target.reference) else {
				return try Mac.setText(target.reference, text, window: window)
			}
			// Page scripts ignore an Accessibility value write, so a web field gets key events, into the focus
			// the snapshot saw on this very field.
			guard let focused = snapshot.focused, focused.attributes["role"] == role,
			      abs(focused.frame.minX - target.frame.minX) <= 1, abs(focused.frame.minY - target.frame.minY) <= 1,
			      abs(focused.frame.width - target.frame.width) <= 1, abs(focused.frame.height - target.frame.height) <= 1
			else {
				throw Refusal(
					"DESKTOP_ACTION_FAILED",
					"This is a web text field, which takes typed text only while it has keyboard focus, and the snapshot shows focus elsewhere. Nothing was typed.",
					hint: "Click the field with desktop_click, inspect the window again, then repeat desktop_type with the new snapshot.",
					fromHost: false
				)
			}
			guard text.utf16.count <= 1000, !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
				throw Refusal(
					"DESKTOP_ACTION_FAILED",
					"A web text field is typed into with key events, which take at most 1000 UTF-16 code units and no newlines, tabs or other control characters. Nothing was typed.",
					hint: "Use desktop_insert with route paste for long or multi-line text, after selecting the field's text if it should be replaced.",
					fromHost: false
				)
			}
			var delivery = try Mac.typeKeys(text, target: KeyboardTarget(window: window, focusedRole: role, focusedFrame: focused.frame))
			delivery.fields = [("receiver", "observed_control")]
			if delivery.state != .confirmedChange, delivery.state != .confirmedNoChange {
				delivery.unverified = true
				delivery.fields.append(("error", .object([("code", "TYPING_UNVERIFIED"), ("message", "The web field's text was typed with key events, but the host could not read back the result."), ("hint", "Inspect the window to check the field before acting again; do not repeat the typing blindly.")])))
			}
			return delivery
		}
	}
}
