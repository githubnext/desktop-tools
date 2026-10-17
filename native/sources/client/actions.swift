import Carbon
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

/// Typed insertion checks focus before every character, so it is kept short enough to finish well within a request.
private let maximumTypedInsertion = 1000

private struct ActionRequest: Decodable {
	enum Operation: String, Decodable {
		case click, type, key, insert, select, scroll, drag, hover, press
		case elementAction = "element-action"
		case setValue = "set-value"
	}

	let op: Operation
	let snapshot: String
	let element: String?
	let text: String?
	let key: String?
	let modifiers: [String]?
	let prefix: String?
	let suffix: String?
	let selection: String?
	let point: PointerPoint?
	let kind: String?
	let direction: String?
	let amount: Int?
	let from: PointerPoint?
	let to: PointerPoint?
	let button: String?
	let duration_ms: Int?
	let action: String?
	let value: UIElementValue?
	let to_snapshot: String?
	let path: [PointerPoint]?
	var route: String?

	/// Modifier keys and drags between windows need real global input; other drags stay in the background.
	var dragsInForeground: Bool {
		op == .drag && (to_snapshot != nil || !(modifiers ?? []).isEmpty)
	}

	func validate() throws {
		guard !snapshot.isEmpty, snapshot.utf16.count <= 256 else {
			throw ActionError("Use a snapshot ID returned by desktop_inspect.")
		}
		if op != .key, op != .drag, modifiers != nil {
			throw ActionError("Only key presses and drags accept modifiers.")
		}
		if op != .select, prefix != nil || suffix != nil || selection != nil {
			throw ActionError("Only text selection accepts prefix, suffix, or selection.")
		}
		if op != .click, kind != nil {
			throw ActionError("Only clicks accept a click kind.")
		}
		if op != .scroll, direction != nil || amount != nil {
			throw ActionError("Only scrolling accepts direction or amount.")
		}
		if op != .drag, from != nil || to != nil || to_snapshot != nil || path != nil {
			throw ActionError("Only dragging accepts endpoints or a path.")
		}
		if op != .elementAction, action != nil {
			throw ActionError("Only element actions accept an action name.")
		}
		if op != .setValue, value != nil {
			throw ActionError("Only set-value accepts a value.")
		}
		if op != .drag, op != .press, button != nil || duration_ms != nil {
			throw ActionError("Only dragging or pressing accepts a button or duration.")
		}
		if op != .insert, route != nil {
			throw ActionError("Only insertion accepts a route.")
		}
		if op != .click, op != .scroll, op != .hover, op != .press, point != nil {
			throw ActionError("Only clicks, scrolling, hovering, or pressing accept a target point.")
		}
		switch op {
		case .hover, .press:
			guard (element == nil) != (point == nil), text == nil, key == nil else {
				throw ActionError("Choose exactly one observed element ID or normalized screenshot point.")
			}
			if let element, element.isEmpty || element.utf16.count > 256 {
				throw ActionError("Choose a literal element ID from the inspected snapshot.")
			}
			try point?.validate()
			if op == .press {
				guard button == nil || ExactWindowHeldPointerButton(rawValue: button!) != nil,
					(1...10000).contains(duration_ms ?? 1000)
				else { throw ActionError("Choose a left or right press lasting 1 to 10000 milliseconds.") }
			}
		case .click, .scroll:
			guard (element == nil) != (point == nil), text == nil, key == nil else {
				throw ActionError("Choose exactly one observed element ID or normalized screenshot point.")
			}
			if let element, element.isEmpty || element.utf16.count > 256 {
				throw ActionError("Choose a literal element ID from the inspected snapshot.")
			}
			try point?.validate()
			if op == .click {
				guard kind == nil || pointerClicks.contains(kind!) else {
					throw ActionError("Choose single, double, right, middle, or triple click.")
				}
			} else {
				guard let direction, ScrollDirection(rawValue: direction) != nil,
					let amount, (1...20).contains(amount)
				else { throw ActionError("Choose up, down, left, or right and 1 to 20 native scroll units.") }
			}
		case .drag:
			if let to_snapshot {
				guard !to_snapshot.isEmpty, to_snapshot.utf16.count <= 256, to_snapshot != snapshot else {
					throw ActionError("Use another window's snapshot ID from desktop_inspect as to_snapshot, or omit it to drag within one window.")
				}
			}
			guard element == nil, text == nil, key == nil, let from, let to,
				from != to || to_snapshot != nil || path != nil
			else {
				throw ActionError("Choose distinct normalized screenshot points for the drag endpoints.")
			}
			try from.validate()
			try to.validate()
			if let path {
				guard to_snapshot == nil else {
					throw ActionError("A drag path stays in one window; omit path to drag into another window.")
				}
				guard (1...DragPolyline.maximumWaypointCount).contains(path.count) else {
					throw ActionError("Give a drag path of 1 to 16 normalized screenshot points.")
				}
				try path.forEach { try $0.validate() }
			}
			let modifiers = modifiers ?? []
			guard modifiers.count <= 4, Set(modifiers).count == modifiers.count,
				modifiers.allSatisfy({ keyboardModifiers[$0] != nil })
			else {
				throw ActionError("Use each of command, control, option, and shift at most once.")
			}
			guard button == nil || ExactWindowHeldPointerButton(rawValue: button!) != nil,
				ExactWindowDragRequest.durationMillisecondsRange.contains(duration_ms ?? 500)
			else { throw ActionError("Choose a left or right drag lasting 1 to 10000 milliseconds.") }
		case .elementAction, .setValue:
			guard let element, !element.isEmpty, element.utf16.count <= 256, key == nil, text == nil else {
				throw ActionError("Choose a literal element ID from the inspected snapshot.")
			}
			if op == .elementAction {
				guard let action, elementActions.contains(action) else {
					throw ActionError("Choose one of \(elementActions.sorted().joined(separator: ", ")).")
				}
			} else {
				switch value {
				case .bool?, .int?:
					break
				case let .double(number)? where number.isFinite:
					break
				default:
					throw ActionError("Set a finite number or true/false; use desktop_type for text.")
				}
			}
		case .type, .select:
			guard let element, !element.isEmpty, element.utf16.count <= 256, key == nil else {
				throw ActionError("Choose a literal element ID from the inspected snapshot.")
			}
			if op == .type {
				guard let text, text.utf16.count <= 8192 else {
					throw ActionError("Replacement text must contain at most 8,192 UTF-16 code units.")
				}
			} else if op == .select {
				guard let text, !text.isEmpty, text.utf16.count <= 4096,
					(prefix?.utf16.count ?? 0) <= 2048, (suffix?.utf16.count ?? 0) <= 2048
				else {
					throw ActionError("Select nonempty text of at most 4,096 UTF-16 code units, with prefix and suffix of at most 2,048 each.")
				}
				if let selection, TextSelectionType(rawValue: selection) == nil {
					throw ActionError("Choose text, cursor_before, or cursor_after selection.")
				}
			}
		case .insert:
			guard element == nil, key == nil, let text, !text.isEmpty, text.utf16.count <= 8192 else {
				throw ActionError("Insert nonempty text of at most 8,192 UTF-16 code units into the observed focused control.")
			}
			guard route == nil || route == "paste" || route == "type" else {
				throw ActionError("Choose the paste or type route, or omit route.")
			}
			if route == "type" {
				guard text.utf16.count <= maximumTypedInsertion else {
					throw ActionError("Typed insertion takes at most \(maximumTypedInsertion) UTF-16 code units; insert longer text in parts.")
				}
				// Typing a newline or tab presses Return or Tab, which can run a command or move focus.
				guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
					throw ActionError(
						"Typed insertion can't contain newlines, tabs or other control characters, because typing them presses keys such as Return.",
						hint: "Insert each line separately and press desktop_key enter or tab between them only where you mean to."
					)
				}
			}
		case .key:
			guard element == nil, text == nil, let key, serviceKey(key) != nil else {
				throw ActionError("Choose a named key or the one printable character a key types, such as , or a.")
			}
			let modifiers = modifiers ?? []
			guard modifiers.count <= 4, Set(modifiers).count == modifiers.count,
				modifiers.allSatisfy({ keyboardModifiers[$0] != nil })
			else {
				throw ActionError("Use each of command, control, option, and shift at most once.")
			}
			// Peekaboo refuses these background chords after admission, which reads as possible dispatch.
			if modifiers == ["command"], let tool = semanticShortcuts[key] {
				throw ActionError(
					"Command-\(key.uppercased()) can't be verified when sent to a background window, so it isn't sent.",
					hint: "Use \(tool) instead; it reports whether it took effect."
				)
			}
		}
	}
}

private struct PointerPoint: Decodable, Equatable {
	let x: Double
	let y: Double

	func validate() throws {
		guard x.isFinite, y.isFinite, (0..<1).contains(x), (0..<1).contains(y) else {
			throw ActionError("Screenshot point coordinates must be at least 0 and less than 1.")
		}
	}

	func mapped(in authority: SnapshotTargetReceipt.CoordinateAuthority) throws -> CGPoint {
		let point = try CaptureCoordinateMapper.globalPoint(
			for: CGPoint(x: x, y: y), in: .normalized, context: authority.context
		)
		guard authority.target.bounds.contains(point) else {
			throw ActionError("The screenshot point is outside its exact captured window.")
		}
		return point
	}
}

/// AXPress stays with desktop_click, whose element route already performs it with tab and focus checks.
let elementActions: Set<String> = [
	"AXShowMenu", "AXIncrement", "AXDecrement", "AXConfirm", "AXCancel", "AXPick", "AXRaise", "AXScrollToVisible",
]
/// Roles whose Accessibility value is one on/off state.
private let booleanValueRoles: Set<String> = ["AXCheckBox", "AXSwitch", "AXToggle", "AXDisclosureTriangle"]
/// Roles whose Accessibility value is one number.
private let numericValueRoles: Set<String> = ["AXSlider", "AXIncrementor", "AXStepper", "AXLevelIndicator"]
private let textValueRoles: Set<String> = [
	"AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField",
]

private let pointerClicks: Set<String> = ["single", "double", "right", "middle", "triple"]
let semanticShortcuts = [
	"w": "desktop_close", "q": "desktop_quit", "h": "desktop_hide", "m": "desktop_minimize",
]
let keyboardModifiers: [String: String] = [
	"command": "cmd", "control": "ctrl", "option": "alt", "shift": "shift",
]
// This contract keeps delete as forward delete; Peekaboo's unqualified delete means backspace.
private let keyboardKeys: [String: String] = {
	var keys = [
		"enter": "return", "tab": "tab", "escape": "escape", "backspace": "delete", "delete": "forwarddelete",
		"up": "up", "down": "down", "left": "left", "right": "right", "space": "space", "home": "home",
		"end": "end", "pageup": "pageup", "pagedown": "pagedown", "help": "help",
	]
	let keypad = (0...9).map { "keypad\($0)" } + [
		"keypaddecimal", "keypadmultiply", "keypadplus", "keypadminus", "keypaddivide", "keypadequals",
		"keypadenter", "keypadclear",
	]
	for name in (1...20).map({ "f\($0)" }) + keypad { keys[name] = name }
	return keys
}()

/// Peekaboo's name for a key. A character names the key that types it on the host's current layout.
func serviceKey(_ key: String) -> String? {
	if let name = keyboardKeys[key] { return name }
	guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first, !scalar.properties.isWhitespace
	else { return nil }
	switch scalar.properties.generalCategory {
	case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
		return nil
	default:
		return "char:" + String(scalar.value, radix: 16)
	}
}

struct ActionError: LocalizedError {
	let message: String
	var hint: String?
	init(_ message: String, hint: String? = nil) {
		self.message = message
		self.hint = hint
	}
	var errorDescription: String? { message }
}

private struct ActionEvidence {
	let outcome: DesktopActionOutcome?
	let target: DesktopTargetIdentity?
	let selected: [DesktopSelectedLeafEvidence]?

	init<T: Sendable>(_ result: UIAutomationActionResult<T>) {
		outcome = result.outcome
		target = result.targetIdentity
		selected = result.selectedLeafEvidence
	}

	init(outcome: DesktopActionOutcome?, target: DesktopTargetIdentity?) {
		self.outcome = outcome
		self.target = target
		selected = nil
	}
}

private struct ActionResult: Encodable {
	var outcome: String
	let action: String
	let snapshot_id: String
	var native_outcome: DesktopActionOutcome?
	var selected_leaf_evidence: [DesktopSelectedLeafEvidence]?
	var selection: TextSelectionResult?
	var element_action: String?
	var previous_value: String?
	var value: String?
	var clipboard_changed: Bool?
	var clipboard_cleanup: String?
	var clipboard_ownership: String?
	var consumption: String?
	var pointer_moved: Bool?
	var destination_receipt: Receipt?
	var release: String?
	var receiver: String?
	var requires_fresh_observation = false
	var error: ActionMessage?
}

private struct ActionMessage: Encodable {
	let code: String
	let message: String
	var hint: String?
	var cause: String?
}

private struct ActionReply: Encodable {
	let success = true
	let data: ActionResult
	let target_receipt: Receipt?
}

func nativeAction(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async throws -> Data {
	let request = try readAction()
	if request.dragsInForeground {
		return try await dragInForeground(client, request, host: handshake.hostIdentity?.processIdentifier)
	}
	var result = ActionResult(outcome: "refused", action: request.op.rawValue, snapshot_id: request.snapshot)
	var receipt: Receipt?
	var lease: SnapshotMutationLease?
	var invoked = false
	do {
		try request.validate()
		let chord = request.key.map { key in
			((request.modifiers ?? []).map { keyboardModifiers[$0]! } + [serviceKey(key)!]).joined(separator: ",")
		}
		result.requires_fresh_observation = true
		guard try await client.ownsSnapshot(snapshotId: request.snapshot) else {
			throw ActionError("This observation no longer belongs to the running desktop. Inspect the window again.")
		}
		let detection = try await client.getDetectionResult(snapshotId: request.snapshot)
		let (context, identity, bounds) = try snapshotWindow(detection)
		receipt = Receipt(
			pid: identity.ownerProcessIdentifier,
			window_id: identity.windowID,
			process_start_identity_decimal: String(identity.ownerProcessStartIdentity)
		)
		if let element = request.element {
			// Native set-value accepts text queries too; this client accepts only a literal observed ID.
			guard let observed = detection.elements.findById(element) else {
				throw ActionError("The element ID is not in this snapshot. Inspect the window again.")
			}
			// Disabled controls still show tooltips, so only hovering may target one.
			guard request.op == .hover || observed.knownIsEnabled != false else {
				throw ActionError("The observed element is disabled.")
			}
			try checkElementRequest(request, observed)
		}
		// Without an observed focused control there's no text to read back, so insertion types into window focus.
		let typesInsertion = request.op == .insert
			&& (request.route == "type" || (request.route == nil && context.focusedElement == nil))
		if request.op == .insert, request.route == "paste", context.focusedElement == nil {
			throw ActionError("The snapshot has no exact focused control to paste into. Click the text field and inspect the window again, or omit route to type into the window's focus.")
		}
		if typesInsertion {
			var effective = request
			effective.route = "type"
			try effective.validate()
			guard (handshake.enabledOperations ?? handshake.supportedOperations).contains(.exactWindowTargetedTypeActions) else {
				throw ActionError("The native runtime does not allow typed insertion. Update the desktop runtime before acting.")
			}
			if IsSecureEventInputEnabled() {
				throw ActionError(
					"Secure keyboard entry is on, as for a password field or a terminal's Secure Keyboard Entry, so typed text can't be delivered. Nothing was typed.",
					hint: "Use a field that isn't secure, or turn off Secure Keyboard Entry in the app."
				)
			}
		}
		if request.op == .insert, !typesInsertion {
			// The GUI owns the snapshot lease and clipboard transaction through consumption and cleanup.
			invoked = true
			let insertion = try await client.literalInsert(snapshot: request.snapshot, text: request.text!)
			result.outcome = insertion.outcome
			result.native_outcome = insertion.native_outcome
			result.clipboard_changed = insertion.clipboard_changed
			result.clipboard_cleanup = insertion.clipboard_cleanup
			result.clipboard_ownership = insertion.clipboard_ownership
			result.consumption = insertion.consumption
			result.requires_fresh_observation = insertion.requires_fresh_observation
			if let error = insertion.error {
				result.error = ActionMessage(code: error.code, message: error.message, hint: error.hint, cause: error.cause)
			}
			guard let target = insertion.target_receipt,
				target.pid == identity.ownerProcessIdentifier, target.window_id == identity.windowID,
				target.process_start_identity_decimal == String(identity.ownerProcessStartIdentity)
			else {
				throw ActionError("Literal insertion returned without its expected exact-window receipt. Inspect before retrying.")
			}
			await explainMinimized(client, &result, receipt: receipt)
			return try JSONEncoder().encode(ActionReply(data: result, target_receipt: receipt))
		}
		let window = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
		var scrollWindow: UIAutomationTarget.ExactWindow?
		if request.op == .scroll {
			// Request-pinned scroll receipts retain the snapshot's focus evidence as well as its geometry.
			scrollWindow = try .init(identity: identity, bounds: bounds, focusedElement: context.focusedElement)
		}
		var point: CGPoint?
		var drag: ExactWindowDragRequest?
		if request.point != nil || request.op == .drag || request.op == .hover || request.op == .press {
			// Normalized coordinates survive host image resizing; authority stays in the bridge's capture.
			let authority = try coordinateAuthority(request.snapshot, detection, window: window)
			point = try request.point?.mapped(in: authority) ?? request.element.map { element in
				// Hover and press act on a point, so an element target resolves to its observed center.
				let frame = detection.elements.findById(element)!.bounds
				let center = CGPoint(x: frame.midX, y: frame.midY)
				guard bounds.contains(center) else {
					throw ActionError("The element's center is outside its exact captured window.")
				}
				return center
			}
			if request.op == .drag {
				// Drag validates the full capture receipt; coordinate authority intentionally omits focus.
				let dragWindow = try UIAutomationTarget.ExactWindow(
					identity: identity, bounds: bounds, focusedElement: context.focusedElement
				)
				let waypoints = try (request.path ?? []).map { try $0.mapped(in: authority) }
				drag = try ExactWindowDragRequest(
					snapshotID: request.snapshot, target: dragWindow,
					from: request.from!.mapped(in: authority), to: request.to!.mapped(in: authority),
					durationMilliseconds: request.duration_ms ?? 500,
					// Four samples per segment keep a path's corners; a straight drag keeps its usual 20.
					steps: min(ExactWindowDragRequest.sampleCountRange.upperBound, max(20, (waypoints.count + 1) * 4)),
					button: request.button.flatMap(ExactWindowHeldPointerButton.init(rawValue:)) ?? .left,
					waypoints: waypoints
				)
				try drag!.validate()
			}
		}
		let host = handshake.hostIdentity?.processIdentifier
		if request.op == .hover, !exposes(point!, in: window, ignoring: host) {
			throw ActionError("Another window covers this point, or the window moved since the snapshot. Inspect the window again; bring it forward with desktop_focus if it is covered.")
		}
		lease = try await client.beginSnapshotMutation(snapshotId: request.snapshot)
		invoked = true
		let evidence: ActionEvidence
		var verified = true
		switch request.op {
		case .hover:
			// Tracking areas follow the real pointer, so hovering moves it; this is foreground input.
			let moved = try await client.moveMouseWithOutcome(to: point!, duration: 250, steps: 15, profile: .linear)
			let location = CGEvent(source: nil)?.location
			result.pointer_moved = location.map { hypot($0.x - point!.x, $0.y - point!.y) <= 1 } ?? false
			verified = result.pointer_moved! && exposes(point!, in: window, ignoring: host)
			evidence = ActionEvidence(outcome: moved.outcome, target: DesktopTargetIdentity(exactWindow: window))
		case .press:
			let released = try await hold(client, ExactWindowHeldPointerRequest(
				point: point!, windowIdentity: identity, windowBounds: bounds,
				button: request.button.flatMap(ExactWindowHeldPointerButton.init(rawValue:)) ?? .left,
				expiresAfterSeconds: Double(request.duration_ms ?? 1000) / 1000 + 2
			), for: request.duration_ms ?? 1000)
			result.release = released.payload.reason.rawValue
			verified = released.payload.reason == .released
			evidence = ActionEvidence(released)
		case .click:
			evidence = try await ActionEvidence(client.clickWithOutcome(
				target: point.map(ClickTarget.coordinates) ?? .elementId(request.element!),
				clickType: request.kind.flatMap(ClickType.init(rawValue:)) ?? .single,
				snapshotId: request.snapshot,
				windowEvidence: .init(identity: identity, bounds: bounds),
				allowsAccessibilityValueDelivery: true
			))
		case .scroll:
			evidence = try await ActionEvidence(client.scrollWithOutcome(.init(
				direction: ScrollDirection(rawValue: request.direction!)!, amount: request.amount!,
				target: request.element, point: point, snapshotId: request.snapshot,
				expectedWindow: scrollWindow!, foreground: false
			)))
		case .drag:
			evidence = try await ActionEvidence(client.dragExactWindow(drag!))
		case .type:
			evidence = try await ActionEvidence(client.setValueWithOutcome(
				target: request.element!, value: .string(request.text!), snapshotId: request.snapshot
			))
		case .setValue:
			let set = try await client.setValueWithOutcome(
				target: request.element!, value: request.value!, snapshotId: request.snapshot
			)
			evidence = ActionEvidence(set)
			result.previous_value = set.payload.oldValue
			result.value = set.payload.newValue
		case .elementAction:
			let performed = try await client.performActionWithOutcome(
				target: request.element!, actionName: request.action!, snapshotId: request.snapshot
			)
			evidence = ActionEvidence(performed)
			result.element_action = performed.payload.actionName
		case .key:
			// Text-action emulation rejects WKWebView's focused receiver; deliver the exact-window key instead.
			if let focusedElement = context.focusedElement {
				result.receiver = "observed_control"
				evidence = try await ActionEvidence(client.hotkeyWithOutcome(
					keys: chord!,
					holdDuration: 0,
					target: .init(windowIdentity: identity, windowBounds: bounds, focusedElement: focusedElement)
				))
			} else {
				// Lists, outlines, canvases and web areas often have no unique observed focus. The host still
				// requires, before each event, that the app's focused element lies in this key window.
				result.receiver = "window_focus"
				evidence = try await ActionEvidence(client.hotkeyWithOutcome(
					keys: chord!,
					holdDuration: 0,
					expectedWindowIdentity: identity,
					expectedWindowBounds: bounds
				))
			}
		case .insert:
			// Typing leaves the clipboard alone. The host checks focus before each character, as for keys.
			if let focusedElement = context.focusedElement {
				result.receiver = "observed_control"
				evidence = try await ActionEvidence(client.typeActionsWithOutcome(
					[.text(request.text!)], cadence: .fixed(milliseconds: 2), snapshotId: request.snapshot,
					target: .init(windowIdentity: identity, windowBounds: bounds, focusedElement: focusedElement)
				))
			} else {
				result.receiver = "window_focus"
				evidence = try await ActionEvidence(client.typeActionsWithOutcome(
					[.text(request.text!)], cadence: .fixed(milliseconds: 2), snapshotId: request.snapshot,
					expectedWindowIdentity: identity, expectedWindowBounds: bounds
				))
			}
		case .select:
			let selected = try await client.selectText(
				target: request.element!,
				request: .init(
					text: request.text!, prefix: request.prefix, suffix: request.suffix,
					selectionType: request.selection.flatMap(TextSelectionType.init(rawValue:)) ?? .text
				),
				snapshotId: request.snapshot
			)
			evidence = ActionEvidence(selected)
			result.selection = selected.payload.textSelection
		}
		result.native_outcome = evidence.outcome
		result.selected_leaf_evidence = evidence.selected
		guard let outcome = evidence.outcome,
			let target = evidence.target?.exactWindow,
			target.identity.hasSameStableReceipt(as: identity), target.bounds == bounds
		else {
			throw ActionError("The action returned without its expected outcome and exact-window receipt. Inspect before retrying.")
		}
		// Every dispatched action consumes this snapshot, including confirmed changes and partial cleanup.
		result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
		try await client.finishSnapshotMutation(lease!, requiresFreshObservation: result.requires_fresh_observation)
		lease = nil
		switch outcome.state {
		case .refused:
			result.outcome = "refused"
		case .indeterminate, .partial:
			result.outcome = "unknown"
		default:
			result.outcome = outcome.evidence == .operationStillRunning || !verified ? "unknown" : "completed"
		}
		// Delivered keystrokes don't show what the receiver did with them unless the host read the change back.
		if request.op == .insert, result.outcome == "completed", outcome.state != .confirmedChange {
			result.outcome = "unknown"
			result.error = ActionMessage(
				code: "INSERTION_UNVERIFIED",
				message: "The text was typed into the window's keyboard focus, but nothing could read back what the receiver did with it.",
				hint: "Inspect the window, or capture it with desktop_screen, to check the text before acting again; do not repeat the insertion blindly."
			)
		}
		if !verified, result.outcome != "refused" {
			result.outcome = "unknown"
			result.error = ActionMessage(
				code: "DESKTOP_ACTION_UNVERIFIED",
				message: request.op == .hover
					? result.pointer_moved == true
						? "The pointer arrived, but the exact window was no longer frontmost there."
						: "The pointer could not be confirmed at the requested point."
					: "The press ended before its planned release (\(result.release ?? "unknown")); the button was released by cleanup.",
				hint: "Inspect the target before retrying; the action may already have happened."
			)
		}
	} catch let failure as DesktopActionFailure {
		result.outcome = failure.outcome.dispatchState.mutationDispatched ? "unknown" : "refused"
		result.native_outcome = failure.outcome
		result.selected_leaf_evidence = failure.selectedLeafEvidence
		let dispatched = failure.outcome.dispatchState.mutationDispatched
		result.requires_fresh_observation = dispatched || failure.outcome.escalation == .refreshTarget
		result.error = ActionMessage(
			code: failure.standardErrorCode?.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: failure.message, hint: failure.hint, cause: failure.causeDescription
		)
		if let lease {
			do {
				try await client.finishSnapshotMutation(lease, requiresFreshObservation: dispatched)
			} catch {
				result.requires_fresh_observation = true
			}
		}
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		if invoked { result.requires_fresh_observation = true }
		let envelope = error as? PeekabooBridgeErrorEnvelope
		result.error = ActionMessage(
			code: envelope?.code.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: error.localizedDescription,
			hint: invoked
				? "Inspect the target before retrying; the action may already have happened."
				: (error as? ActionError)?.hint
		)
		// Unknown completion leaves the host's pending lease in place, including client death or response loss.
	}
	await explainMinimized(client, &result, receipt: receipt)
	return try JSONEncoder().encode(ActionReply(data: result, target_receipt: receipt))
}

/// Replaces a refusal's low-level cause when the target window turns out to be minimized.
///
/// A minimized window can't take input, and Accessibility reads of it fail with raw errors; the check
/// runs only after a refusal, so actions that succeed pay nothing for it.
private func explainMinimized(_ client: PeekabooBridgeClient, _ result: inout ActionResult, receipt: Receipt?) async {
	guard result.outcome == "refused", let receipt, let windowID = receipt.window_id,
		let inventory = try? await client.listWindowMutationInventory(target: .application("PID:\(receipt.pid)")),
		let window = inventory.items.first(where: { $0.windowID == windowID }),
		window.mutationIdentity.map({ String($0.ownerProcessStartIdentity) }) == receipt.process_start_identity_decimal,
		window.isMinimized
	else { return }
	result.error = ActionMessage(
		code: "WINDOW_MINIMIZED",
		message: "The target window is minimized, so nothing was sent to it.",
		hint: "Restore it with desktop_restore, using its target from desktop_windows, then inspect it again before acting.",
		cause: result.error?.message
	)
	result.requires_fresh_observation = true
}

/// Drags with real global input: into another window, in the same app or another one, or with modifier keys held.
///
/// Exact-window delivery can't leave its window or hold keys for the system, so this moves the real pointer and
/// holds the modifier keys with global events, and pressing in the source may activate its app. Nothing can confirm
/// the effect, so a dispatched drag is unknown.
private func dragInForeground(_ client: PeekabooBridgeClient, _ request: ActionRequest, host: pid_t?) async throws -> Data {
	var result = ActionResult(outcome: "refused", action: "drag", snapshot_id: request.snapshot)
	var receipt: Receipt?
	var leases: [SnapshotMutationLease] = []
	var invoked = false
	do {
		try request.validate()
		result.requires_fresh_observation = true
		let source = try await dragEnd(client, snapshot: request.snapshot, point: request.from!)
		let across = request.to_snapshot != nil
		let destination = try await dragEnd(client, snapshot: request.to_snapshot ?? request.snapshot, point: request.to!)
		receipt = source.receipt
		if across { result.destination_receipt = destination.receipt }
		guard exposes(source.point, in: source.window, ignoring: host) else {
			throw ActionError("Another window covers the start point, or its window moved since the snapshot. Inspect it again; bring it forward with desktop_focus if it is covered.")
		}
		guard exposes(destination.point, in: destination.window, ignoring: host) else {
			throw ActionError(across
				? "Another window covers the end point, or its window moved since the snapshot. Arrange the windows so both points are visible, then inspect both again."
				: "Another window covers the end point, or the window moved since the snapshot. Inspect it again; bring it forward with desktop_focus if it is covered.")
		}
		let waypoints = try (request.path ?? []).map { try $0.mapped(in: source.authority) }
		guard waypoints.allSatisfy({ exposes($0, in: source.window, ignoring: host) }) else {
			throw ActionError("Another window covers a point on the path, or the window moved since the snapshot. Inspect it again; bring it forward with desktop_focus if it is covered.")
		}
		let modifiers = (request.modifiers ?? []).map { keyboardModifiers[$0]! }
		leases.append(try await client.beginSnapshotMutation(snapshotId: request.snapshot))
		if let destination = request.to_snapshot {
			leases.append(try await client.beginSnapshotMutation(snapshotId: destination))
		}
		invoked = true
		// Rest on the source first, as a person would; some views only start a drag from a hovered item.
		_ = try await client.moveMouseWithOutcome(to: source.point, duration: 200, steps: 12, profile: .linear)
		let duration = request.duration_ms ?? 800
		let dragged = try await client.dragWithOutcome(PeekabooBridgeDragRequest(DragOperationRequest(
			from: source.point, to: destination.point, duration: duration,
			steps: max(10, min(120, duration / 16), (waypoints.count + 1) * 4),
			modifiers: modifiers.isEmpty ? nil : modifiers.joined(separator: ","),
			button: request.button.flatMap(DragButton.init(rawValue:)) ?? .left, profile: .linear,
			waypoints: waypoints
		)))
		result.native_outcome = dragged.outcome
		let location = CGEvent(source: nil)?.location
		result.pointer_moved = location.map { hypot($0.x - destination.point.x, $0.y - destination.point.y) <= 1 } ?? false
		for lease in leases {
			try await client.finishSnapshotMutation(lease, requiresFreshObservation: true)
		}
		leases = []
		result.outcome = "unknown"
		let held = (request.modifiers ?? []).isEmpty ? "" : ", holding \((request.modifiers ?? []).joined(separator: " and ")),"
		result.error = ActionMessage(
			code: "DESKTOP_ACTION_UNVERIFIED",
			message: across
				? "The drag was sent as real pointer input\(held) which moved the pointer and may have activated the source app. A drop between windows can't be confirmed."
				: "The drag was sent as real pointer input\(held) which moved the pointer and may have activated the app. Its effect can't be confirmed.",
			hint: across
				? "Inspect both windows to see whether the drop happened. Never repeat the drag blindly."
				: "Inspect the window to see what the drag did. Never repeat the drag blindly."
		)
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		if !invoked {
			for lease in leases {
				try? await client.finishSnapshotMutation(lease, requiresFreshObservation: false)
			}
		}
		let failure = error as? DesktopActionFailure
		let envelope = error as? PeekabooBridgeErrorEnvelope
		result.native_outcome = failure?.outcome
		result.error = ActionMessage(
			code: failure?.standardErrorCode?.rawValue ?? envelope?.code.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: failure?.message ?? error.localizedDescription,
			hint: invoked ? "Inspect the windows before retrying; part of the drag may already have happened." : failure?.hint
		)
		// Unknown completion leaves the host's pending leases in place, as for other actions.
	}
	return try JSONEncoder().encode(ActionReply(data: result, target_receipt: receipt))
}

/// One end of a foreground drag: its exact window, the global point in it, and the snapshot's coordinate authority.
private func dragEnd(
	_ client: PeekabooBridgeClient, snapshot: String, point: PointerPoint
) async throws -> (
	window: UIAutomationTarget.ExactWindow, point: CGPoint, receipt: Receipt,
	authority: SnapshotTargetReceipt.CoordinateAuthority
) {
	guard try await client.ownsSnapshot(snapshotId: snapshot) else {
		throw ActionError("An observation no longer belongs to the running desktop. Inspect both windows again.")
	}
	let detection = try await client.getDetectionResult(snapshotId: snapshot)
	let (_, identity, bounds) = try snapshotWindow(detection)
	let window = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
	let authority = try coordinateAuthority(snapshot, detection, window: window)
	return (window, try point.mapped(in: authority), Receipt(
		pid: identity.ownerProcessIdentifier,
		window_id: identity.windowID,
		process_start_identity_decimal: String(identity.ownerProcessStartIdentity)
	), authority)
}

/// Holds the button for the duration, then releases it; the owner is always disconnected afterward.
private func hold(
	_ client: PeekabooBridgeClient, _ request: ExactWindowHeldPointerRequest, for milliseconds: Int
) async throws -> UIAutomationActionResult<ExactWindowHeldPointerTermination> {
	let owner = try await client.createExactWindowHeldPointerOwner()
	do {
		let begun = try await client.beginExactWindowPointerHold(owner: owner, request: request)
		try? await Task.sleep(for: .milliseconds(milliseconds))
		let released = try await client.releaseExactWindowPointerHold(owner: owner, receipt: begun.payload)
		_ = try? await client.disconnectExactWindowHeldPointerOwner(owner)
		return released
	} catch {
		// Disconnecting releases a button still held; the hold's expiry is the host's own backstop.
		_ = try? await client.disconnectExactWindowHeldPointerOwner(owner)
		throw error
	}
}

/// Whether the exact window is on screen at its snapshot bounds and frontmost at the point.
///
/// The host's own overlays ignore the mouse, so they never count as covering the point.
private func exposes(_ point: CGPoint, in window: UIAutomationTarget.ExactWindow, ignoring host: pid_t?) -> Bool {
	guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
	else { return false }
	for info in list {
		guard let frame = (info[kCGWindowBounds as String] as? NSDictionary)
			.flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
			frame.contains(point)
		else { continue }
		if let host, info[kCGWindowOwnerPID as String] as? pid_t == host { continue }
		if (info[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
		let bounds = window.bounds
		return info[kCGWindowNumber as String] as? Int == window.identity.windowID
			&& abs(frame.minX - bounds.minX) < 1 && abs(frame.minY - bounds.minY) < 1
			&& abs(frame.width - bounds.width) < 1 && abs(frame.height - bounds.height) < 1
	}
	return false
}

/// Element actions and values act only on what the snapshot observed the element to support.
private func checkElementRequest(_ request: ActionRequest, _ observed: DetectedElement) throws {
	let role = observed.attributes["role"] ?? ""
	switch request.op {
	case .elementAction:
		let action = request.action!
		guard let listed = observed.attributes["actions"] else {
			throw ActionError("This snapshot did not record the element's advertised actions. Inspect the window again.")
		}
		let advertised = listed.split(separator: ",").map(String.init)
		guard advertised.contains(action) else {
			let offered = advertised.filter(elementActions.contains)
			throw ActionError("The observed \(role.isEmpty ? "element" : role) does not advertise \(action). "
				+ (offered.isEmpty ? "It advertises none of the supported element actions." : "It advertises \(offered.joined(separator: ", ")).")
				+ (action == "AXShowMenu" ? " A right click with desktop_click may still open a menu." : ""))
		}
	case .setValue:
		if textValueRoles.contains(role) {
			throw ActionError("Use desktop_type to replace a text control's value.")
		}
		let boolean = booleanValueRoles.contains(role)
		guard boolean || numericValueRoles.contains(role) else {
			throw ActionError("Set values only on sliders, steppers, level indicators, checkboxes, switches, and disclosure triangles; this element is \(role.isEmpty ? "unknown" : role). Choose a pop-up button's item by clicking the button and then the item.")
		}
		if case .bool = request.value!, !boolean {
			throw ActionError("A \(role) takes a number, not true or false.")
		}
		if boolean {
			guard case .bool = request.value! else {
				throw ActionError("A \(role) takes true or false.")
			}
			guard ["0", "1", "true", "false"].contains(observed.value ?? "") else {
				throw ActionError("This \(role) was observed in a mixed or unreadable state, so on/off cannot be verified. Use desktop_click.")
			}
		}
		// Native set-value reports an unsettable target as possibly dispatched, so refuse it here first.
		if observed.attributes["isValueSettable"] == "false" {
			let pressable = observed.attributes["actions"]?.split(separator: ",").contains("AXPress") == true
			guard boolean, pressable else {
				throw ActionError(boolean
					? "This \(role) has no settable value and does not advertise AXPress. Inspect it again, or use desktop_click."
					: "This \(role) has no settable value. Use desktop_element_action with AXIncrement or AXDecrement if it advertises them.")
			}
		}
	default:
		break
	}
}

func snapshotWindow(
	_ detection: ElementDetectionResult
) throws -> (WindowContext, WindowMutationIdentity, CGRect) {
	guard let context = detection.metadata.windowContext,
		let identity = context.windowMutationIdentity,
		let bounds = context.windowBounds,
		context.windowID == identity.windowID,
		context.applicationProcessId == identity.ownerProcessIdentifier
	else {
		throw ActionError("This observation has no exact-window action target. Inspect the window again.")
	}
	return (context, identity, bounds)
}

func coordinateAuthority(
	_ snapshot: String, _ detection: ElementDetectionResult, window: UIAutomationTarget.ExactWindow
) throws -> SnapshotTargetReceipt.CoordinateAuthority {
	let authority = try SnapshotTargetReceiptPlanner.assemble(
		snapshotID: snapshot, detectionResult: detection
	).receipt.requireCoordinateAuthority()
	guard authority.target == window, let captured = authority.context.logicalBounds,
		window.bounds.contains(captured), !detection.screenshotPath.isEmpty
	else { throw ActionError("This observation has no pixel-backed coordinate authority for its exact window.") }
	return authority
}

private func readAction() throws -> ActionRequest {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		data.append(chunk)
		guard data.count <= 65_536 else { throw ActionError("The desktop action request exceeds 64 KiB.") }
	}
	return try JSONDecoder().decode(ActionRequest.self, from: data)
}
