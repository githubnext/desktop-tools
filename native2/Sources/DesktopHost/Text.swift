import Carbon.HIToolbox
import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

// desktop_set_value, desktop_element_action, desktop_select, desktop_insert and desktop_fill_password: Node's
// argument checks from src/client.ts's validateAction, and the native client's checks from its actions.swift
// (checkElementRequest) and password.swift.

/// Roles whose Accessibility value is one on/off state.
private let booleanValueRoles: Set<String> = ["AXCheckBox", "AXSwitch", "AXToggle", "AXDisclosureTriangle"]
/// Roles whose Accessibility value is one number.
private let numericValueRoles: Set<String> = ["AXSlider", "AXIncrementor", "AXStepper", "AXLevelIndicator"]
/// Roles whose Accessibility value is one date, which the host writes as an NSDate.
private let dateValueRoles: Set<String> = ["AXDateTimeArea", "AXDateField", "AXTimeField"]
private let textValueRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]

/// The element actions desktop_element_action takes, in the order Node lists them; AXPress stays with desktop_click.
private let supportedElementActions = [
	"AXShowMenu", "AXIncrement", "AXDecrement", "AXConfirm", "AXCancel", "AXPick", "AXRaise", "AXScrollToVisible",
]

private let dateKeyboardRoute = "To enter the date from the keyboard instead, click the control's first field (such as the month) with desktop_click, type its digits with desktop_key, and press Tab to move to the next field, or Up and Down to step the focused field; then inspect to read the value back."
private let keyboardRoute = "If the date control refuses Accessibility, click its first field (such as the month) with desktop_click, type its digits with desktop_key, and press Tab to move to the next field, or Up and Down to step the focused field; then inspect to read the value back."

private let secureFieldRefusal = Refusal(
	"SECURE_FIELD_REQUIRES_FILL",
	"This is a secure text field, such as a password field, and text is never typed, set or selected in it. Nothing was sent.",
	hint: "Fill password fields with desktop_fill_password, from a Keychain item or with the user's approval.",
	fromHost: false
)

/// The native client's own refusal, which carries no host outcome.
private func clientRefusal(_ message: String, hint: String? = nil) -> Refusal {
	Refusal("DESKTOP_ACTION_FAILED", message, hint: hint, fromHost: false)
}

/// Runs a host delivery, reporting a failure that may have sent input as an unknown delivery with its error.
private func reporting(_ work: () throws -> Delivery) throws -> Delivery {
	do { return try work() } catch let failure as Indeterminate {
		var delivery = failure.delivery
		delivery.fields.append(("error", .object([
			"code": JSON(failure.code), "message": JSON(failure.message), "hint": failure.hint.map(JSON.string),
			"cause": failure.cause.map(JSON.string),
		])))
		return delivery
	}
}

/// What a paste or a fill reports in place of the fields act derives from a delivery.
struct ActionReport: Sendable {
	var outcome: String
	var native: JSON?
	var fields: [(String, JSON)]
	var fresh: Bool
}

extension Tools {
	static func elementArgument(_ arguments: JSON) throws -> String {
		guard let id = arguments["element"]?.string, (1...256).contains(id.utf16.count) else {
			throw ToolError("Choose an element ID from the inspected snapshot.")
		}
		return id
	}

	// MARK: desktop_set_value

	static func setValue(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let id = try elementArgument(arguments)
		let requested: RequestedValue
		switch arguments["value"] {
		case let .bool(flag)?: requested = .bool(flag)
		case let .number(number)? where number.isFinite: requested = .number(number)
		case let .string(text)?:
			guard let date = canonicalDate(text) else {
				throw ToolError("Set a date as ISO 8601: 2026-10-17, 2026-10-17T15:30 (local time) or 2026-10-17T15:30:00Z. Use desktop_type for text.")
			}
			requested = .string(date)
		default: throw ToolError("Set a finite number, true/false or an ISO 8601 date; use desktop_type for text.")
		}
		var result = await act("set-value", snapshotID: snapshotID, element: id, precheck: { _, target in
			try checkSetValue(target!, requested)
		}) { snapshot, target in
			try reporting {
				let set = try Mac.setValue(target!.reference, requested, elementID: id, window: window(snapshot))
				var delivery = set.delivery
				if let previous = set.previous { delivery.fields.append(("previous_value", JSON(previous))) }
				delivery.fields.append(("value", JSON(set.value)))
				return delivery
			}
		}
		// A date control that refuses Accessibility can still take the date from the keyboard.
		if case .string = requested, result.outcome != "completed", var data = try? JSON(parsing: result.text), var action = data["action"] {
			action.set("keyboard_route", JSON(keyboardRoute))
			data.set("action", action)
			result.text = data.text
		}
		return result
	}

	/// The native client's checks of a value against the observed element, before any input.
	private static func checkSetValue(_ observed: Element, _ value: RequestedValue) throws {
		if isSecure(observed) { throw secureFieldRefusal }
		let role = observed.attributes["role"] ?? ""
		let isString = if case .string = value { true } else { false }
		if textValueRoles.contains(role) { throw clientRefusal("Use desktop_type to replace a text control's value.") }
		if dateValueRoles.contains(role) {
			guard isString else { throw clientRefusal("A \(role) takes an ISO 8601 date, such as 2026-10-17T15:30.") }
			guard observed.attributes["isValueSettable"] != "false" else {
				throw clientRefusal("This \(role) has no settable value. " + dateKeyboardRoute)
			}
			return
		}
		if isString {
			throw clientRefusal("Only date and time controls take a date; this element is \(role.isEmpty ? "unknown" : role).")
		}
		let boolean = booleanValueRoles.contains(role)
		guard boolean || numericValueRoles.contains(role) else {
			throw clientRefusal("Set values only on sliders, steppers, level indicators, checkboxes, switches, and disclosure triangles; this element is \(role.isEmpty ? "unknown" : role). Choose a pop-up button's item by clicking the button and then the item.")
		}
		let isBool = if case .bool = value { true } else { false }
		if isBool, !boolean { throw clientRefusal("A \(role) takes a number, not true or false.") }
		if boolean {
			guard isBool else { throw clientRefusal("A \(role) takes true or false.") }
			guard ["0", "1", "true", "false"].contains(observed.value ?? "") else {
				throw clientRefusal("This \(role) was observed in a mixed or unreadable state, so on/off cannot be verified. Use desktop_click.")
			}
		}
		// Native set-value reports an unsettable target as possibly dispatched, so it is refused here first.
		if observed.attributes["isValueSettable"] == "false" {
			let pressable = observed.attributes["actions"]?.split(separator: ",").contains("AXPress") == true
			guard boolean, pressable else {
				throw clientRefusal(boolean
					? "This \(role) has no settable value and does not advertise AXPress. Inspect it again, or use desktop_click."
					: "This \(role) has no settable value. Use desktop_element_action with AXIncrement or AXDecrement if it advertises them.")
			}
		}
	}

	/// An ISO 8601 date or date-time as the UTC instant a date control stores, to the second; a date alone is local
	/// midnight and a time without an offset is local. Ported from src/date-value.ts.
	static func canonicalDate(_ text: String) -> String? {
		guard let match = text.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:\d{2})?)?/) else { return nil }
		var year = Int(match.1)!
		let month = Int(match.2)!, day = Int(match.3)!
		let hour = match.4.map { Int($0)! } ?? 0, minute = match.5.map { Int($0)! } ?? 0, second = match.6.map { Int($0)! } ?? 0
		guard (1...12).contains(month), day >= 1, hour <= 23, minute <= 59, second <= 59 else { return nil }
		// JavaScript's Date reads years 0 to 99 as 1900 to 1999.
		if year < 100 { year += 1900 }
		let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
		guard day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] else { return nil }
		let wall = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second
		var time: Int
		if let zone = match.7 {
			let offset = zone == "Z" ? 0 : (zone.first == "-" ? -1 : 1) * (Int(zone.dropFirst().prefix(2))! * 60 + Int(zone.suffix(2))!)
			time = wall - offset * 60
		} else {
			// Local time: the offset in effect at that instant, rechecked once across a change of offset.
			let zone = TimeZone.current
			let first = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wall)))
			time = wall - first
			let second = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(time)))
			if second != first { time = wall - second }
		}
		let days = Int((Double(time) / 86_400).rounded(.down))
		let seconds = time - days * 86_400
		let (y, m, d) = civilFromDays(days)
		let pad = { (value: Int, width: Int) in String(repeating: "0", count: max(0, width - String(value).count)) + String(value) }
		guard (0...9999).contains(y) else { return nil }
		return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(seconds / 3600, 2)):\(pad(seconds / 60 % 60, 2)):\(pad(seconds % 60, 2))Z"
	}

	/// Days since 1970-01-01 in the proleptic Gregorian calendar, as JavaScript's Date counts them.
	private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
		let y = month <= 2 ? year - 1 : year
		let era = (y >= 0 ? y : y - 399) / 400
		let yoe = y - era * 400
		let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
		let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
		return era * 146_097 + doe - 719_468
	}

	private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
		let z = days + 719_468
		let era = (z >= 0 ? z : z - 146_096) / 146_097
		let doe = z - era * 146_097
		let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
		let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
		let mp = (5 * doy + 2) / 153
		let day = doy - (153 * mp + 2) / 5 + 1
		let month = mp < 10 ? mp + 3 : mp - 9
		return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
	}

	// MARK: desktop_element_action

	static func elementAction(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let id = try elementArgument(arguments)
		guard let name = arguments["action"]?.string, supportedElementActions.contains(name) else {
			throw ToolError("Choose one of \(supportedElementActions.joined(separator: ", ")).")
		}
		return await act("element-action", snapshotID: snapshotID, element: id, precheck: { _, target in
			let observed = target!
			guard let listed = observed.attributes["actions"] else {
				throw clientRefusal("This snapshot did not record the element's advertised actions. Inspect the window again.")
			}
			let advertised = listed.split(separator: ",").map(String.init)
			guard advertised.contains(name) else {
				let role = observed.attributes["role"] ?? ""
				let offered = advertised.filter(supportedElementActions.contains)
				throw clientRefusal("The observed \(role.isEmpty ? "element" : role) does not advertise \(name). "
					+ (offered.isEmpty ? "It advertises none of the supported element actions." : "It advertises \(offered.joined(separator: ", ")).")
					+ (name == "AXShowMenu" ? " A right click with desktop_click may still open a menu." : ""))
			}
		}) { snapshot, target in
			try reporting {
				var delivery = try Mac.performAction(target!.reference, name, window: window(snapshot))
				delivery.fields.append(("element_action", JSON(name)))
				return delivery
			}
		}
	}

	// MARK: desktop_select

	static func select(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let id = try elementArgument(arguments)
		guard let text = arguments["text"]?.string, (1...4096).contains(text.utf16.count) else {
			throw ToolError("Selection text must contain 1 to 4096 UTF-16 code units.")
		}
		for key in ["prefix", "suffix"] {
			if let context = arguments[key], context.string.map({ $0.utf16.count <= 2048 }) != true {
				throw ToolError("Selection context must contain at most 2048 UTF-16 code units.")
			}
		}
		let kind: SelectionKind
		if let selection = arguments["selection"] {
			guard let chosen = selection.string.flatMap(SelectionKind.init(rawValue:)) else {
				throw ToolError("Choose text, cursor_before, or cursor_after for selection.")
			}
			kind = chosen
		} else {
			kind = .text
		}
		let prefix = arguments["prefix"]?.string, suffix = arguments["suffix"]?.string
		// Selecting changes no content, and read-only text, such as a PDF page, reports itself disabled.
		return await act("select", snapshotID: snapshotID, element: id, allowsDisabled: true, precheck: { _, target in
			if isSecure(target!) { throw secureFieldRefusal }
		}) { snapshot, target in
			try reporting {
				let (delivery, selection) = try Mac.selectText(target!.reference, text: text, prefix: prefix, suffix: suffix, kind: kind, window: window(snapshot))
				var result = delivery
				result.fields.append(("selection", selection.json))
				return result
			}
		}
	}

	// MARK: desktop_insert

	static func insert(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		if let format = arguments["format"] {
			return try await insertAttachment(arguments, snapshotID: snapshotID, format: format)
		}
		guard let text = arguments["text"]?.string, (1...8192).contains(text.utf16.count) else {
			throw ToolError("Inserted text must contain 1 to 8192 UTF-16 code units.")
		}
		let route = arguments["route"]
		guard route == nil || route == "paste" || route == "type" else { throw ToolError("Choose the paste or type route, or omit route.") }
		// Typing a newline or tab presses Return or Tab, which can run a command or move focus.
		let typedRefusal: Refusal? = if text.utf16.count > 1000 {
			clientRefusal("Typed insertion takes at most 1000 UTF-16 code units; insert longer text in parts.")
		} else if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
			clientRefusal(
				"Typed insertion can't contain newlines, tabs or other control characters, because typing them presses keys such as Return.",
				hint: "Insert each line separately and press desktop_key enter or tab between them only where you mean to."
			)
		} else {
			nil
		}
		let send = {
			let observed = await Snapshots.shared.get(snapshotID)
			// Without an observed focused control there's no text to read back, so insertion types into window focus.
			let types = route == "type" || (route == nil && observed?.focused == nil)
			if types {
				return await act("insert", snapshotID: snapshotID, element: nil, early: route == "type" ? typedRefusal : nil, precheck: { _, _ in
					if let typedRefusal { throw typedRefusal }
					if IsSecureEventInputEnabled() {
						throw clientRefusal(
							"Secure keyboard entry is on, as for a password field or a terminal's Secure Keyboard Entry, so typed text can't be delivered. Nothing was typed.",
							hint: "Use a field that isn't secure, or turn off Secure Keyboard Entry in the app."
						)
					}
				}) { snapshot, _ in
					let focused = snapshot.focused
					var delivery = try Mac.insertKeys(text, target: KeyboardTarget(window: window(snapshot), focusedRole: focused?.attributes["role"], focusedFrame: focused?.frame))
					delivery.fields = [("receiver", JSON(focused == nil ? "window_focus" : "observed_control"))]
					// Delivered keystrokes don't show what the receiver did with them.
					if delivery.outcome == "completed", delivery.state != .confirmedChange {
						delivery.unverified = true
						delivery.fields.append(("error", .object([
							("code", "INSERTION_UNVERIFIED"),
							("message", "The text was typed into the window's keyboard focus, but nothing could read back what the receiver did with it."),
							("hint", "Inspect the window, or capture it with desktop_screen, to check the text before acting again; do not repeat the insertion blindly."),
						])))
					}
					return delivery
				}
			}
			return await perform("insert", snapshotID: snapshotID, precheck: { snapshot in
				guard snapshot.focused != nil else {
					throw clientRefusal("The snapshot has no exact focused control to paste into. Click the text field and inspect the window again, or omit route to type into the window's focus.")
				}
			}) { snapshot in
				let focused = snapshot.focused!
				let target = KeyboardTarget(window: window(snapshot), focusedRole: focused.attributes["role"], focusedFrame: focused.frame)
				return paste(try await run { try Mac.pasteText(text, target: target) })
			}
		}
		if let expect = try expectation(arguments) { return try await expectAfter(expect) { await send() } }
		return await send()
	}

	/// An image or file references pasted through the clipboard, checked and read as Node does before any input.
	private static func insertAttachment(_ arguments: JSON, snapshotID: String, format: JSON) async throws -> ToolResult {
		let allowed = ["snapshot", "format", format == "files" ? "paths" : "path", "clipboard", "expect"]
		guard arguments.keys?.allSatisfy(allowed.contains) == true else {
			throw ToolError("Insert an image with format image and path, or files with format files and paths, without text or route.")
		}
		let clipboard = arguments["clipboard"]
		guard clipboard == nil || clipboard == "restore" || clipboard == "replace" else {
			throw ToolError("Choose clipboard restore or replace, or omit it.")
		}
		let payload: PastePayload
		if format == "files" {
			guard let list = arguments["paths"]?.array, (1...32).contains(list.count),
			      let paths = Optional(list.compactMap(\.string)), paths.count == list.count, paths.allSatisfy(isAbsoluteClipboardPath)
			else { throw ToolError("Insert 1–32 absolute file paths.") }
			try checkFileReferences(paths)
			payload = .files(try Mac.clipboardFileURLs(paths), paths: paths)
		} else {
			guard format == "image", let path = arguments["path"]?.string, isAbsoluteClipboardPath(path) else {
				throw ToolError("Insert format image with one absolute image path, or format files with paths.")
			}
			let data = try clipboardImageFile(path)
			payload = .image(data, try Mac.clipboardImageInput(data))
		}
		let replace = clipboard == "replace"
		let send = {
			await perform("insert", snapshotID: snapshotID, precheck: { snapshot in
				guard snapshot.focused != nil else {
					throw clientRefusal("The snapshot has no exact focused control to paste into. Click the receiver and inspect the window again.")
				}
			}) { snapshot in
				let focused = snapshot.focused!
				let target = KeyboardTarget(window: window(snapshot), focusedRole: focused.attributes["role"], focusedFrame: focused.frame)
				return paste(try await run { try Mac.pasteAttachment(payload, replace: replace, target: target) })
			}
		}
		if let expect = try expectation(arguments) { return try await expectAfter(expect) { await send() } }
		return await send()
	}

	private static func paste(_ report: PasteReport) -> ActionReport {
		ActionReport(outcome: report.outcome, native: report.native, fields: report.fields, fresh: report.fresh)
	}

	// MARK: desktop_fill_password

	static func fillPassword(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let id = try elementArgument(arguments)
		let named = ["service", "server", "text"].filter { arguments[$0] != nil }
		let strings = ["service", "server", "account"].allSatisfy { key in
			arguments[key].map { $0.string.map { (1...1024).contains($0.utf16.count) } == true } ?? true
		}
		guard named.count == 1, strings, arguments["text"] == nil || arguments["account"] == nil else {
			throw ToolError("Name one Keychain item by service or server, with an optional account, or supply text; not more than one.")
		}
		// The secret is never quoted back, so its problems are described without it.
		if let text = arguments["text"], text.string.map({ (1...1024).contains($0.utf16.count) }) != true {
			throw ToolError("The password text must contain 1 to 1024 UTF-16 code units.")
		}
		let account = arguments["account"]?.string
		let secret: Hooks.SecureTextFillContext.Secret = if let service = arguments["service"]?.string {
			.keychain(Hooks.KeychainItem(kind: .generic, name: service, account: account))
		} else if let server = arguments["server"]?.string {
			.keychain(Hooks.KeychainItem(kind: .internet, name: server, account: account))
		} else {
			.text(arguments["text"]!.string!)
		}
		let client = Hooks.call?.client ?? 0
		return await perform("fill", snapshotID: snapshotID, fill: true, precheck: { snapshot in
			guard let observed = snapshot.elements[id] else {
				throw clientRefusal("The element ID is not in this snapshot. Inspect the window again.")
			}
			guard isSecure(observed) else { throw clientRefusal("This is not a secure text field. Use desktop_type for other text fields.") }
			// Clicking to focus the field could also act on the page, so the field must already have keyboard focus.
			guard let focused = snapshot.focused, focused.attributes["role"] == observed.attributes["role"],
			      abs(focused.frame.minX - observed.frame.minX) <= 1, abs(focused.frame.minY - observed.frame.minY) <= 1,
			      abs(focused.frame.width - observed.frame.width) <= 1, abs(focused.frame.height - observed.frame.height) <= 1
			else {
				throw clientRefusal(
					"The password field doesn't have keyboard focus in this snapshot. Nothing was typed.",
					hint: "Click the field with desktop_click, inspect the window again, then fill it with the new snapshot."
				)
			}
		}) { snapshot in
			let focused = snapshot.focused!
			let target = KeyboardTarget(window: window(snapshot), focusedRole: focused.attributes["role"], focusedFrame: focused.frame)
			guard let authorize = Hooks.secureTextFill else {
				var refusal = Refusal("FILL_REFUSED", Hooks.noSecureTextFill)
				refusal.reason = "operation_unsupported"
				throw refusal
			}
			try await run { try target.window.check() }
			let field = try await run { try Mac.fillField(target) }
			let decision = await authorize(Hooks.SecureTextFillContext(
				client: client, targetProcess: snapshot.pid, applicationName: field.applicationName,
				bundleIdentifier: field.bundleIdentifier, webHost: field.webHost, secret: secret
			))
			let value: String
			switch decision {
			case let .fill(secret): value = secret
			case let .refuse(message):
				var refusal = Refusal("FILL_REFUSED", message)
				refusal.reason = "permission_denied"
				throw refusal
			}
			let delivery = try await run { try Mac.fill(value, into: field, target: target) }
			guard delivery.state == .confirmedChange else {
				return ActionReport(outcome: "unknown", native: nil, fields: [("error", .object([
					("code", "FILL_UNVERIFIED"),
					("message", "The password was typed, but the field didn't show the expected number of characters."),
					("hint", "Inspect the window. Clear the field before filling it again; don't submit the form unverified."),
				]))], fresh: true)
			}
			return ActionReport(outcome: "completed", native: nil, fields: [], fresh: true)
		}
	}

	// MARK: Runner

	/// An insertion or fill on a snapshot, which reports its own outcome and fields, with the snapshot checks,
	/// refusal shapes and follow-up observation act gives every other action. A fill's result has no native outcome
	/// and words host refusals as FILL_REFUSED, as the native client's fill does.
	private static func perform(
		_ name: String, snapshotID: String, fill: Bool = false, precheck: (Snapshot) throws -> Void,
		deliver: @escaping @Sendable (Snapshot) async throws -> ActionReport
	) async -> ToolResult {
		var action: [(String, JSON)] = [("outcome", "refused"), ("action", JSON(name)), ("snapshot_id", JSON(snapshotID))]
		var receipt: JSON?
		func finish(_ outcome: String) async -> ToolResult {
			if let receipt { action.append(("target_receipt", receipt)) }
			if outcome == "refused", let receipt, let pid = receipt["pid"]?.int.flatMap(Int32.init(exactly:)), let window = receipt["window_id"]?.int {
				let message = action.first { $0.0 == "error" }?.1["message"]?.string ?? ""
				let availability = await targetAvailability(pid: pid, windowID: window, message: message)
				if availability["availability"]?["state"]?.string != "available" {
					action.append(("target_availability", availability["availability"] ?? .null))
				}
			}
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: outcome, isError: true)
		}
		func refused(_ refusal: Refusal) async -> ToolResult {
			// The native client refuses before the host with fresh observation required; a host refusal requires
			// one only when the target itself became unavailable.
			let fresh = !refusal.fromHost || refusal.reason == "target_unavailable"
			var error: [(String, JSON)] = [("code", JSON(fill && refusal.fromHost ? "FILL_REFUSED" : refusal.code)), ("message", JSON(refusal.message))]
			if let hint = refusal.hint { error.append(("hint", JSON(hint))) }
			if !fill, let cause = refusal.cause { error.append(("cause", JSON(cause))) }
			action += refusal.fields + [("requires_fresh_observation", JSON(fresh)), ("error", .object(error))]
			if !fill, refusal.fromHost { action.append(("native_outcome", refusal.outcome)) }
			return await finish("refused")
		}

		guard let observed = await Snapshots.shared.get(snapshotID) else {
			action += [("requires_fresh_observation", true), ("error", .object([("code", "invalidRequest"), ("message", "Invalid producer-bound snapshot reference")]))]
			return await finish("refused")
		}
		receipt = .object([
			("pid", JSON(observed.pid)), ("window_id", JSON(observed.windowID)),
			("process_start_identity_decimal", JSON(String(observed.generation))),
		])
		do { try precheck(observed) } catch let refusal as Refusal {
			return await refused(refusal)
		} catch {
			return await refused(clientRefusal((error as? ToolError)?.message ?? String(describing: error)))
		}
		let snapshot: Snapshot
		do { snapshot = try await Snapshots.shared.spend(snapshotID) } catch {
			action += [("requires_fresh_observation", true), ("error", .object([("code", "invalidRequest"), ("message", JSON(String(((error as? ToolError)?.message ?? "\(error)").dropFirst("invalidRequest: ".count))))]))]
			return await finish("refused")
		}
		let report: ActionReport
		do { report = try await deliver(snapshot) } catch let refusal as Refusal {
			await Snapshots.shared.release(snapshotID)
			return await refused(refusal)
		} catch let failure as Indeterminate {
			action[0] = ("outcome", "unknown")
			var error: [(String, JSON)] = [("code", JSON(failure.code)), ("message", JSON(failure.message))]
			if let hint = failure.hint { error.append(("hint", JSON(hint))) }
			action += [("requires_fresh_observation", true), ("error", .object(error))]
			if !fill { action.append(("native_outcome", failure.delivery.json)) }
			return await finish("unknown")
		} catch {
			action[0] = ("outcome", "unknown")
			action += [("requires_fresh_observation", true), ("error", .object([
				("code", "DESKTOP_ACTION_FAILED"), ("message", JSON((error as? ToolError)?.message ?? String(describing: error))),
				("hint", JSON(fill ? "Inspect the window before retrying; the password may already have been typed." : "Inspect the target before retrying; the action may already have happened.")),
			]))]
			return await finish("unknown")
		}
		if !report.fresh { await Snapshots.shared.release(snapshotID) }
		action[0] = ("outcome", JSON(report.outcome))
		if let native = report.native { action.append(("native_outcome", native)) }
		action += report.fields + [("requires_fresh_observation", JSON(report.fresh))]
		guard report.outcome == "completed" else {
			if let receipt { action.append(("target_receipt", receipt)) }
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: report.outcome, isError: true)
		}
		action.append(("target_receipt", receipt!))
		// Observation is separate from delivery: its failure must not turn completed input into a retry.
		do {
			var (fresh, image) = try await observation(pid: snapshot.pid, windowID: snapshot.windowID)
			fresh.set("action", .object(action))
			return ToolResult(text: try boundedObservation(fresh), outcome: "completed", image: image)
		} catch {
			action += [
				("observation_error", JSON((error as? ToolError)?.message ?? String(describing: error))),
				("message", "The action completed, but a fresh observation was unavailable. Inspect again to verify the result; do not repeat the action blindly."),
			]
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: "completed")
		}
	}
}
