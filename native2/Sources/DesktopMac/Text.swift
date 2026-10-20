import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Element values, element actions, text selection and typed insertion, ported from Peekaboo's ActionInputDriver,
// ElementValueVerification, ElementDateValue, TextSelectionRequest and TypeService (MIT).

/// A host failure that may have sent input, as Peekaboo's indeterminate DesktopActionFailure reports it.
public struct Indeterminate: Error {
	public let delivery: Delivery
	public let code: String
	public let message: String
	public let hint: String?
	public let cause: String?
	public init(_ delivery: Delivery, code: String = "DESKTOP_ACTION_FAILED", _ message: String, hint: String? = nil, cause: String? = nil) {
		self.delivery = delivery
		self.code = code
		self.message = message
		self.hint = hint
		self.cause = cause
	}
}

private func unsupported(_ message: String, code: String = "DESKTOP_ACTION_FAILED") -> Refusal {
	var refusal = Refusal(code, message)
	refusal.reason = "operation_unsupported"
	return refusal
}

private func invalid(_ message: String, code: String = "DESKTOP_ACTION_FAILED") -> Refusal {
	var refusal = Refusal(code, message)
	refusal.reason = "invalid_request"
	return refusal
}

private func onMainThread<T>(_ work: () throws -> T) rethrows -> T {
	if Thread.isMainThread { return try work() }
	return try DispatchQueue.main.sync(execute: work)
}

// MARK: - Values

/// A tagged native scalar, keeping integer and floating readback apart.
enum Readback: Equatable {
	case bool(Bool), int(Int), double(Double), string(String)

	init?(_ value: Any?) {
		guard let value else { return nil }
		if let string = value as? String {
			self = .string(string)
		} else if let number = value as? NSNumber {
			let encoding = String(cString: number.objCType)
			if CFGetTypeID(number) == CFBooleanGetTypeID() {
				self = .bool(number.boolValue)
			} else if ["f", "d", "D"].contains(encoding) {
				self = .double(number.doubleValue)
			} else {
				guard !["C", "S", "I", "L", "Q"].contains(encoding) || number.uint64Value <= UInt64(Int.max) else { return nil }
				self = .int(number.intValue)
			}
		} else {
			return nil
		}
	}

	var display: String {
		switch self {
		case let .bool(value): String(value)
		case let .int(value): String(value)
		case let .double(value): Int(exactly: value).map(String.init) ?? String(value)
		case let .string(value): value
		}
	}

	var isFinite: Bool {
		if case let .double(value) = self { return value.isFinite }
		return true
	}

	/// Whether this readback is the requested value, as ElementValueMutationSemantics.matches compares them.
	func matches(_ expected: Readback) -> Bool {
		switch (expected, self) {
		case let (.bool(want), .bool(have)): want == have
		case let (.bool(want), .int(have)): have == (want ? 1 : 0)
		case let (.bool(want), .double(have)): have == (want ? 1 : 0)
		case let (.int(want), .int(have)): want == have
		case let (.double(want), .double(have)): abs(want - have) <= max(1e-9, abs(want) * 1e-9)
		case let (.double(want), .int(have)): abs(want - Double(have)) <= max(1e-9, abs(want) * 1e-9)
		case let (.string(want), .string(have)): want == have
		default: false
		}
	}
}

/// The historical presentation of a raw value, as NativeElementValuePresentation.describe gives it.
func describe(_ value: Any?) -> String? {
	switch value {
	case let value as String: value
	case let value as Bool: String(value)
	case let value as Int: String(value)
	case let value as Double: String(value)
	case let value as Float: String(value)
	case let value?: String(describing: value)
	case nil: nil
	}
}

/// A requested value: a boolean, a number or an ISO 8601 date string.
public enum RequestedValue: Sendable {
	case bool(Bool), number(Double), string(String)
}

private let accessibilityValue = "accessibility_value"
private let accessibilityAction = "accessibility_action"

/// What a value write did, with the previous and new values the result reports.
public struct ValueResult: Sendable {
	public let delivery: Delivery
	public let previous: String?
	public let value: String
}

/// A UTC ISO 8601 formatter to the second; a new one per use, since formatters aren't Sendable.
private func isoFormatter() -> ISO8601DateFormatter {
	let formatter = ISO8601DateFormatter()
	formatter.formatOptions = [.withInternetDateTime]
	formatter.timeZone = TimeZone(secondsFromGMT: 0)
	return formatter
}

private func dateString(_ date: Date) -> String { isoFormatter().string(from: date) }

/// A UTC ISO 8601 date that round-trips exactly, as ElementDateValue accepts it.
private func dateValue(_ text: String) -> Date? {
	let formatter = isoFormatter()
	guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
	return date
}

private func unverifiedValue(_ attribute: String) -> Indeterminate {
	Indeterminate(
		Delivery(state: .indeterminate, mechanism: accessibilityValue, evidence: "completion_unknown", units: 1),
		"The accessibility value write was accepted, but its requested result could not be verified.",
		hint: "Observe the exact target before deciding whether to retry; do not reuse the prior snapshot.",
		cause: "Post-dispatch readback did not confirm \(attribute)."
	)
}

/// Polls up to 14 times within 250 ms, as Peekaboo observes a mutation.
private func observe(_ matches: () -> Bool) -> Bool {
	let deadline = ContinuousClock.now + .milliseconds(250)
	for index in 0..<14 {
		if matches() { return true }
		if index == 13 || ContinuousClock.now >= deadline { break }
		Thread.sleep(forTimeInterval: 0.018)
	}
	return matches()
}

extension Mac {
	/// Sets a slider, stepper, checkbox, switch or date control's value through Accessibility and reads it back;
	/// a read-only toggle gets at most one AXPress.
	public static func setValue(_ element: AXUIElement, _ value: RequestedValue, elementID: String, window: ClickWindow) throws -> ValueResult {
		AXUIElementSetMessagingTimeout(element, 1)
		let role = AX.string(element, kAXRoleAttribute)
		let subrole = AX.string(element, kAXSubroleAttribute)
		let valueSettable = settable(element, kAXValueAttribute)
		let selectedSettable = settable(element, kAXSelectedAttribute)
		let current = AX.value(element, kAXValueAttribute)
		let previous = describe(current) ?? (AX.value(element, kAXSelectedAttribute) as? Bool).map { String($0) }
		let toggles: Set<String> = ["AXCheckBox", "AXSwitch", "AXToggle", "AXDisclosureTriangle"]

		func requestedBool() throws -> Bool {
			if case let .bool(flag) = value { return flag }
			if case let .number(number) = value, number == 0 || number == 1 { return number == 1 }
			throw invalid("Cannot set value on \(elementID): A \(role ?? "element") takes true or false.", code: "invalidRequest")
		}
		func toggleState(_ readback: Readback?) -> Bool? {
			switch readback {
			case let .bool(flag)?: flag
			case let .int(number)? where number == 0 || number == 1: number == 1
			case let .double(number)? where number == 0 || number == 1: number == 1
			default: nil
			}
		}
		func notSettable(_ reason: String) -> Refusal {
			invalid("Cannot set value on \(elementID): \(reason)", code: "invalidRequest")
		}

		if let role, toggles.contains(role), !valueSettable, !selectedSettable, actions(element).contains("AXPress") {
			let wanted = try requestedBool()
			guard let before = toggleState(Readback(current)) else { throw notSettable("Accessibility value is not settable") }
			if before == wanted {
				return ValueResult(delivery: Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil), previous: previous, value: String(before))
			}
			try window.check()
			switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
			case .success: break
			case .actionUnsupported: throw notSettable("Accessibility action is not supported")
			case .invalidUIElement: throw notSettable("Accessibility element is stale; run see again")
			default:
				throw Indeterminate(
					Delivery(state: .indeterminate, mechanism: accessibilityAction, evidence: "completion_unknown", units: 1),
					"Accessibility press returned without reliable completion evidence.",
					hint: "Observe the exact target before deciding whether to press it again; do not reuse the prior snapshot."
				)
			}
			var after: Bool?
			guard observe({ after = toggleState(Readback(AX.value(element, kAXValueAttribute))); return after == wanted }), let after else {
				throw Indeterminate(
					Delivery(state: .indeterminate, mechanism: accessibilityAction, evidence: "completion_unknown", units: 1),
					"The toggle was pressed, but its requested state could not be verified.",
					hint: "Observe the exact target before deciding whether to press it again; do not reuse the prior snapshot.",
					cause: "Post-press readback did not confirm the requested state."
				)
			}
			return ValueResult(delivery: Delivery(state: .confirmedChange, mechanism: accessibilityAction, evidence: "verified_change", units: nil), previous: previous, value: String(after))
		}
		if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
			throw notSettable("Direct value setting is not allowed for secure text fields")
		}
		guard valueSettable || selectedSettable else { throw notSettable("Accessibility value is not settable") }

		if !valueSettable, selectedSettable {
			let wanted = try requestedBool()
			let before = AX.value(element, kAXSelectedAttribute) as? Bool
			if before == wanted {
				return ValueResult(delivery: Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil), previous: previous, value: String(wanted))
			}
			try window.check()
			let error = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, (wanted ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
			guard error == .success else { throw notSettable("Accessibility attribute is not supported") }
			guard observe({ AX.value(element, kAXSelectedAttribute) as? Bool == wanted }) else { throw unverifiedValue("AXSelected") }
			let state: Delivery.State = before == nil ? .dispatchedUnverified : .confirmedChange
			return ValueResult(delivery: Delivery(state: state, mechanism: accessibilityValue, evidence: before == nil ? "delivery_accepted" : "verified_change", units: nil), previous: previous, value: String(wanted))
		}

		// Date and time controls report an NSDate; the request and readback are both UTC ISO 8601 to the second.
		if let before = current as? Date, case let .string(text) = value {
			guard let wanted = dateValue(text) else { throw notSettable("Accessibility value is not settable") }
			if dateString(before) == text {
				return ValueResult(delivery: Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil), previous: previous, value: dateString(before))
			}
			try window.check()
			_ = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, wanted as NSDate)
			// Controls apply the date synchronously, but may publish it on the next run-loop turn.
			let deadline = ContinuousClock.now + .seconds(1)
			while true {
				if let after = AX.value(element, kAXValueAttribute) as? Date, dateString(after) == text {
					return ValueResult(delivery: Delivery(state: .confirmedChange, mechanism: accessibilityValue, evidence: "verified_change", units: nil), previous: previous, value: dateString(after))
				}
				guard ContinuousClock.now < deadline else { throw unverifiedValue("AXSetValue") }
				Thread.sleep(forTimeInterval: 0.05)
			}
		}

		let before = Readback(current)
		let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
		let booleanRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle"]
		let wanted: Readback
		if textRoles.contains(role ?? "") || current is String {
			switch value {
			case let .string(text): wanted = .string(text)
			case let .bool(flag): wanted = .string(String(flag))
			case let .number(number): wanted = .string(Int(exactly: number).map(String.init) ?? String(number))
			}
		} else if booleanRoles.contains(role ?? "") || before.map({ if case .bool = $0 { true } else { false } }) == true {
			wanted = .bool(try requestedBool())
		} else if role == "AXSlider" {
			guard case let .number(number) = value else { throw notSettable("A \(role!) takes a number") }
			wanted = .double(number)
		} else {
			switch (value, before) {
			case let (.number(number), .int?):
				guard let integer = Int(exactly: number) else { throw notSettable("A whole number is required") }
				wanted = .int(integer)
			case let (.number(number), _): wanted = .double(number)
			case let (.bool(flag), _): wanted = .bool(flag)
			case let (.string(text), _): wanted = .string(text)
			}
		}
		if let before, before.matches(wanted) {
			return ValueResult(delivery: Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil), previous: previous, value: before.display)
		}
		let native: CFTypeRef = switch wanted {
		case let .bool(flag): (flag ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
		case let .int(number): NSNumber(value: number)
		case let .double(number): NSNumber(value: number)
		case let .string(text): text as CFString
		}
		try window.check()
		switch AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, native) {
		case .success: break
		case .attributeUnsupported, .actionUnsupported: throw notSettable("Accessibility attribute is not supported")
		case .invalidUIElement: throw notSettable("Accessibility element is stale; run see again")
		default: throw unverifiedValue("AXSetValue")
		}
		var after: Readback?
		guard observe({ after = Readback(AX.value(element, kAXValueAttribute)); return after?.isFinite == true && after!.matches(wanted) }), let after else {
			throw unverifiedValue("AXSetValue")
		}
		let state: Delivery.State = current == nil ? .dispatchedUnverified : .confirmedChange
		return ValueResult(delivery: Delivery(state: state, mechanism: accessibilityValue, evidence: current == nil ? "delivery_accepted" : "verified_change", units: nil), previous: previous, value: after.display)
	}

	/// One advertised Accessibility action, performed from its own thread so a modal it opens can't block the host.
	public static func performAction(_ element: AXUIElement, _ name: String, window: ClickWindow) throws -> Delivery {
		AXUIElementSetMessagingTimeout(element, 1)
		guard actions(element).contains(name) else { throw unsupported("Accessibility action is not supported") }
		if name == "AXShowMenu" { return try showMenu(element, window: window) }
		try window.check()
		let error = AXUIElementPerformAction(element, name as CFString)
		switch error {
		case .success: return .accepted(accessibilityAction)
		case .actionUnsupported: throw unsupported("Accessibility action is not supported")
		case .invalidUIElement: throw unsupported("Accessibility element is stale; run see again")
		case .apiDisabled: throw unsupported("Accessibility permission is denied")
		default:
			throw Indeterminate(
				Delivery(state: .indeterminate, mechanism: accessibilityAction, evidence: "completion_unknown", units: 1),
				"Accessibility action \(name) returned without reliable completion evidence.",
				hint: "Observe the exact target before deciding whether to repeat this action.",
				cause: "AXError \(error.rawValue)"
			)
		}
	}
}

// MARK: - Text selection

public enum SelectionKind: String, Sendable {
	case text, cursor_before, cursor_after
}

/// The matched text and the range selected, as TextSelectionResult encodes them.
public struct SelectionResult: Sendable {
	public let matched: CFRange
	public let selected: CFRange
	public let kind: SelectionKind
	public var json: JSON {
		.object([
			("matchedRange", .object([("location", JSON(matched.location)), ("length", JSON(matched.length))])),
			("selectedRange", .object([("location", JSON(selected.location)), ("length", JSON(selected.length))])),
			("selectionType", JSON(kind.rawValue)),
		])
	}
}

/// Finds the one literal occurrence of `text` with the given context, in UTF-16 units.
func resolveSelection(_ text: String, prefix: String?, suffix: String?, kind: SelectionKind, in source: String) throws -> SelectionResult {
	func refused(_ message: String) -> Refusal { invalid("Invalid input: \(message)") }
	let value = source as NSString
	let before = Array((prefix ?? "").utf16), after = Array((suffix ?? "").utf16)
	let units = Array(source.utf16)
	var search = NSRange(location: 0, length: value.length)
	var match: CFRange?
	while search.length > 0 {
		let found = value.range(of: text, options: .literal, range: search)
		guard found.location != NSNotFound else { break }
		let end = found.location + found.length
		if found.location >= before.count, end + after.count <= units.count,
		   units[(found.location - before.count)..<found.location].elementsEqual(before),
		   units[end..<(end + after.count)].elementsEqual(after)
		{
			guard match == nil else { throw refused("Selection text is ambiguous; provide a unique prefix or suffix") }
			match = CFRange(location: found.location, length: found.length)
		}
		let next = found.location + 1
		search = NSRange(location: next, length: value.length - next)
	}
	guard let match else { throw refused("Selection text and context were not found in the target") }
	guard match.length > 0 else { throw refused("Selection range is not representable") }
	let selected = switch kind {
	case .text: match
	case .cursor_before: CFRange(location: match.location, length: 0)
	case .cursor_after: CFRange(location: match.location + match.length, length: 0)
	}
	return SelectionResult(matched: match, selected: selected, kind: kind)
}

extension Mac {
	/// Selects text, or places the caret, in a native text control by its AXSelectedTextRange.
	public static func selectText(
		_ element: AXUIElement, text: String, prefix: String?, suffix: String?, kind: SelectionKind, window: ClickWindow
	) throws -> (Delivery, SelectionResult) {
		AXUIElementSetMessagingTimeout(element, 1)
		let unavailable = Refusal("DESKTOP_ACTION_FAILED", "The target text or selection is unreadable or changed; observe it again.")
		guard AX.string(element, kAXRoleAttribute) != "AXSecureTextField", AX.string(element, kAXSubroleAttribute) != "AXSecureTextField",
		      settable(element, kAXSelectedTextRangeAttribute)
		else { throw unsupported("The nonsecure target must expose a settable AXSelectedTextRange.") }
		func state() -> (String, CFRange?)? {
			guard let text = AX.string(element, kAXValueAttribute) else { return nil }
			guard let raw = AX.value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return (text, nil) }
			var range = CFRange()
			guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return (text, nil) }
			return (text, range)
		}
		func same(_ a: (String, CFRange?)?, _ b: (String, CFRange?)) -> Bool {
			guard let a else { return false }
			return a.0.utf16.elementsEqual(b.0.utf16) && a.1?.location == b.1?.location && a.1?.length == b.1?.length
		}
		try window.check()
		guard let source = state() else { throw unavailable }
		let selection = try resolveSelection(text, prefix: prefix, suffix: suffix, kind: kind, in: source.0)
		let desired = (source.0, Optional(selection.selected))
		let current = state()
		guard same(current, source) || same(current, desired) else { throw unavailable }
		if same(current, desired) {
			return (Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil), selection)
		}
		try window.check()
		var range = selection.selected
		guard let wanted = AXValueCreate(.cfRange, &range) else { throw unsupported("The target does not support native text selection.") }
		let error = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, wanted)
		switch error {
		case .success: break
		case .attributeUnsupported, .actionUnsupported: throw unsupported("The target does not support native text selection.")
		default:
			throw Indeterminate(
				Delivery(state: .indeterminate, mechanism: accessibilityValue, evidence: "completion_unknown", units: 1),
				"The selection write returned without acceptance evidence.",
				hint: "Observe the exact field before deciding whether to retry.", cause: "AXError \(error.rawValue)"
			)
		}
		guard observe({ same(state(), desired) }) else { throw unverifiedValue("textSelection") }
		return (Delivery(state: .confirmedChange, mechanism: accessibilityValue, evidence: "verified_change", units: 1), selection)
	}
}

// MARK: - Typed insertion

extension Mac {
	/// Literal text as Unicode key events to the exact window's keyboard focus, without clearing it first. Focus is
	/// checked before each character; typing that stops partway reports how many events went out.
	public static func insertKeys(_ text: String, target: KeyboardTarget) throws -> Delivery {
		let focused = try requireKeyboardFocus(target)
		if secureFocus(focused) { throw secureFocusRefusal }
		let source = CGEventSource(stateID: .hidSystemState)
		var sent = 0
		for character in text {
			if sent > 0 {
				do { _ = try requireKeyboardFocus(target) } catch {
					return Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: sent)
				}
			}
			let units = Array(String(character).utf16)
			for down in [true, false] {
				guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
				event.flags = []
				event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
				event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.window.pid))
				if let post = skyLightPostToPid { post(target.window.pid, event) } else { event.postToPid(target.window.pid) }
				sent += 1
				if down { usleep(1000) }
			}
			usleep(2000)
		}
		usleep(10_000)
		return Delivery(state: .dispatchedUnverified, mechanism: "window_targeted_events", evidence: "delivery_accepted", units: sent)
	}
}
