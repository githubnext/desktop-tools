import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// Dialogs, ported from Peekaboo's DialogService (targeted discovery, DialogHierarchyReader,
// DialogElementClassifier, DialogMetadataReader, prepared button presses and background text entry) (MIT).

/// One window of the dialog's app, as desktop_windows listed it.
public struct DialogWindow: Sendable {
	public let id: Int
	public let title: String
	public let bounds: CGRect
	public let isMinimized: Bool
	public init(id: Int, title: String, bounds: CGRect, isMinimized: Bool) {
		self.id = id
		self.title = title
		self.bounds = bounds
		self.isMinimized = isMinimized
	}
}

/// What desktop_dialog lists: the dialog's window, its owner's generation and the dialog's contents.
public struct DialogRead: Sendable {
	public let window: DialogWindow
	public let generation: UInt64
	public let applicationName: String
	public let dialog: JSON
	public let buttons: [(title: String, isEnabled: Bool, isDefault: Bool)]
	public let fields: [(index: Int, title: String?, value: String?, placeholder: String?, isEnabled: Bool)]
	public let staticTexts: [String]
	public let others: JSON
	public let isFileDialog: Bool
}

/// The dialog answer that was sent, with Peekaboo's details.
public struct DialogAnswer: Sendable {
	public let delivery: Delivery
	public let details: [(String, String)]
	public let windowID: Int
}

/// The answer was sent, but its effect wasn't confirmed.
public struct DialogUnconfirmed: Error {
	public let delivery: Delivery
	public let message: String
	public let details: [(String, String)]
	/// The dialog's window when the failure is attributed to it, as text entry's are.
	public var windowID: Int?
}

/// A refusal attributed to the dialog's window, after the dialog was resolved.
public struct DialogRefusal: Error {
	public let refusal: Refusal
	public let windowID: Int
}

/// An AX element that compares as Accessibility does, so traversals can mark it visited.
private struct Node: Hashable {
	let element: AXUIElement
	static func == (a: Node, b: Node) -> Bool { CFEqual(a.element, b.element) }
	func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Peekaboo's DialogAXReadRunner budget for one discovery or metadata read.
private struct Budget {
	let deadline = Date().addingTimeInterval(5)
	func check() throws {
		guard Date() < deadline else { throw refusal("Dialog read timed out before it finished.") }
	}
}

private func refusal(_ message: String, hint: String? = nil, reason: String = "target_unavailable") -> Refusal {
	var refusal = Refusal("DESKTOP_ACTION_FAILED", message, hint: hint)
	refusal.reason = reason
	return refusal
}

private let unreadable = "Dialog hierarchy classification or children could not be read completely."
private let relist = "List the dialog again and prepare a fresh exact action."

private func copy(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
	var value: CFTypeRef?
	let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
	return (error, value)
}

/// A string attribute, attributed strings included; nil when missing or of another type.
private func text(_ element: AXUIElement, _ name: String) -> String? {
	let (error, value) = copy(element, name)
	guard error == .success, let value else { return nil }
	if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
	if CFGetTypeID(value) == CFAttributedStringGetTypeID() { return unsafeDowncast(value, to: NSAttributedString.self).string }
	return nil
}

private func flag(_ element: AXUIElement, _ name: String) -> Bool? {
	let (error, value) = copy(element, name)
	guard error == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
	return value as? Bool
}

private func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
	let (error, value) = copy(element, name)
	guard error == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID(), let values = value as? [AnyObject],
	      values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
	else { return [] }
	return values.map { unsafeDowncast($0, to: AXUIElement.self) }
}

/// AXorcist's default child collection: structural children, then navigation alternatives unless `strict`.
private let alternativeChildren = [
	"AXVisibleChildren", "AXWebAreaChildren", "AXApplicationNavigation", "AXApplicationElements",
	"AXBodyArea", "AXSplitGroupContents", "AXLayoutAreaChildren", "AXGroupChildren", "AXContents",
	"AXChildrenInNavigationOrder", "AXSelectedChildren", "AXRows", "AXColumns", "AXTabs",
]

private func children(_ element: AXUIElement, strict: Bool) -> [AXUIElement] {
	var result: [AXUIElement] = []
	var seen: Set<Node> = []
	func append(_ list: [AXUIElement]) {
		for child in list where result.count < 50000 && seen.insert(Node(element: child)).inserted { result.append(child) }
	}
	append(elements(element, kAXChildrenAttribute))
	if !strict { for name in alternativeChildren { append(elements(element, name)) } }
	if text(element, kAXRoleAttribute) == "AXApplication" {
		append(elements(element, kAXWindowsAttribute))
		if let focused = AX.element(copy(element, kAXFocusedUIElementAttribute).1) { append([focused]) }
	}
	return result
}

/// Elements with one of `roles`, depth first from `root`; static text stays out of nested apps and windows.
private func collect(_ root: AXUIElement, roles: Set<String>, structuralTextOnly: Bool = false, budget: Budget) throws -> [AXUIElement] {
	var result: [AXUIElement] = []
	var visited: Set<Node> = []
	var stack = [root]
	while let element = stack.popLast() {
		try budget.check()
		guard visited.insert(Node(element: element)).inserted else { continue }
		let role = text(element, kAXRoleAttribute)
		if let role, roles.contains(role) { result.append(element) }
		if structuralTextOnly, !CFEqual(element, root), role == "AXApplication" || role == "AXWindow" { continue }
		stack.append(contentsOf: children(element, strict: structuralTextOnly).reversed())
	}
	return result
}

private struct Evidence {
	let role, subrole, roleDescription, identifier, title: String
	static let titleHints = ["open", "save", "export", "import", "choose", "replace"]

	var isStructural: Bool {
		["AXSheet", "AXDialog"].contains(role) || ["AXSheet", "AXDialog", "AXSystemDialog", "AXAlert"].contains(subrole)
	}
	var filePanelIdentifier: Bool { identifier.contains("NSOpenPanel") || identifier.contains("NSSavePanel") }
	var isLegacyDialog: Bool {
		guard ["AXWindow", "AXUnknown"].contains(role) else { return false }
		return roleDescription.localizedCaseInsensitiveContains("dialog") || filePanelIdentifier
			|| Self.titleHints.contains { title.localizedCaseInsensitiveContains($0) }
	}
	var isFileDialog: Bool { filePanelIdentifier || Self.titleHints.contains { title.localizedCaseInsensitiveContains($0) } }
}

/// A hierarchy read that must succeed completely, as DialogHierarchyReader requires.
private func strictAttribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
	let (error, value) = copy(element, name)
	switch error {
	case .attributeUnsupported, .noValue: return nil
	case .success:
		guard let value else { throw refusal(unreadable) }
		return value
	default: throw refusal(unreadable)
	}
}

private func hierarchyNode(_ element: AXUIElement) throws -> (Evidence, [AXUIElement]) {
	func string(_ name: String) throws -> String? {
		guard let value = try strictAttribute(element, name) else { return nil }
		guard let string = value as? String else { throw refusal(unreadable) }
		return string
	}
	func list(_ name: String) throws -> [AXUIElement] {
		guard let value = try strictAttribute(element, name) else { return [] }
		guard CFGetTypeID(value) == CFArrayGetTypeID(), let values = value as? [AnyObject],
		      values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
		else { throw refusal(unreadable) }
		return values.map { unsafeDowncast($0, to: AXUIElement.self) }
	}
	guard let role = try string(kAXRoleAttribute), !role.isEmpty else { throw refusal(unreadable) }
	let evidence = Evidence(
		role: role, subrole: try string(kAXSubroleAttribute) ?? "", roleDescription: try string(kAXRoleDescriptionAttribute) ?? "",
		identifier: try string(kAXIdentifierAttribute) ?? "", title: try string(kAXTitleAttribute) ?? "")
	var seen: Set<Node> = []
	let children = (try list("AXSheets") + list(kAXChildrenAttribute)).filter { seen.insert(Node(element: $0)).inserted }
	return (evidence, children)
}

private struct Candidate {
	let window: DialogWindow
	let axWindow: AXUIElement
	let dialog: AXUIElement
}

/// The app's windows by window number, as Accessibility lists them.
private func axWindows(_ pid: pid_t) -> [Int: AXUIElement] {
	let app = AXUIElementCreateApplication(pid)
	AXUIElementSetMessagingTimeout(app, 1)
	var result: [Int: AXUIElement] = [:]
	for window in elements(app, kAXWindowsAttribute) {
		AXUIElementSetMessagingTimeout(window, 1)
		if let id = AX.windowID(window), AX.pid(window) == pid { result[id] = window }
	}
	return result
}

/// The dialogs in each window: structural ones (sheets, dialogs, alerts), else, when reading, legacy windows that look like dialogs.
private func candidates(pid: pid_t, generation: UInt64, windowID: Int?, windows: [DialogWindow], structuralOnly: Bool) throws -> [Candidate] {
	let filtered = windowID.map { id in windows.filter { $0.id == id } } ?? windows
	if windowID != nil, filtered.count != 1 {
		throw refusal(filtered.isEmpty ? "The dialog window selector matched no exact window." : "The dialog window selector is ambiguous across \(filtered.count) windows.",
		              hint: "Candidate window IDs: \(filtered.isEmpty ? "none" : filtered.map { String($0.id) }.joined(separator: ", ")). Use one exact --window-id.")
	}
	let ax = axWindows(pid)
	let budget = Budget()
	var structural: [Candidate] = []
	var legacy: [Candidate] = []
	for window in filtered {
		try budget.check()
		guard let axWindow = ax[window.id] else { continue }
		var found: [AXUIElement] = []
		var legacyFound: [AXUIElement] = []
		var visited: Set<Node> = []
		var parents: [Node: AXUIElement] = [:]
		var stack = [axWindow]
		while let element = stack.popLast() {
			try budget.check()
			guard visited.insert(Node(element: element)).inserted else { continue }
			let (evidence, children) = try hierarchyNode(element)
			if evidence.isStructural { found.append(element) } else if evidence.isLegacyDialog { legacyFound.append(element) }
			for child in children where parents[Node(element: child)] == nil && !CFEqual(child, axWindow) {
				parents[Node(element: child)] = element
			}
			stack.append(contentsOf: children.reversed())
		}
		// A window can itself be a dialog while hosting a sheet, and a sheet can host another, such as an Open panel
		// opened from a sheet. Each blocks the dialog enclosing it, so only the innermost are active; siblings stay
		// distinct candidates (Peekaboo's DialogTraversal, #148).
		let members = Set(found.map { Node(element: $0) })
		var enclosing: Set<Node> = []
		for dialog in found {
			var seen: Set<Node> = [Node(element: dialog)]
			var next = parents[Node(element: dialog)]
			while let current = next, seen.insert(Node(element: current)).inserted {
				if members.contains(Node(element: current)) { enclosing.insert(Node(element: current)) }
				next = parents[Node(element: current)]
			}
		}
		for dialog in found where !enclosing.contains(Node(element: dialog)) && AX.pid(dialog) == pid {
			structural.append(Candidate(window: window, axWindow: axWindow, dialog: dialog))
		}
		for dialog in legacyFound where AX.pid(dialog) == pid { legacy.append(Candidate(window: window, axWindow: axWindow, dialog: dialog)) }
	}
	guard startIdentity(pid).value == generation else {
		throw refusal("Dialog owner changed process generation during planning.", hint: "List the application and dialog again before retrying.")
	}
	return structuralOnly || !structural.isEmpty ? structural : legacy
}

/// The one dialog the target selects, or Peekaboo's refusal naming why not.
private func onlyCandidate(pid: pid_t, windowID: Int?, windows: [DialogWindow], structuralOnly: Bool) throws -> (Candidate, UInt64) {
	guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, let generation = startIdentity(pid).value else {
		throw refusal("Dialog target owner is unavailable: Application 'PID:\(pid)' not found")
	}
	let found = try candidates(pid: pid, generation: generation, windowID: windowID, windows: windows, structuralOnly: structuralOnly)
	guard found.count == 1 else {
		let hint: String
		if let windowID {
			hint = found.isEmpty
				? "Window ID \(windowID) did not retain a structural dialog. If it is a blank-title transient sheet CGWindow, use the titled parent AX window ID for PID \(pid) from window list."
				: "Window ID \(windowID) contains \(found.count) simultaneous structural dialogs or sheets. Wait for or dismiss the extra dialog, then list the retained parent window again."
		} else {
			let ids = Set(found.map(\.window.id)).sorted()
			hint = "Candidate window IDs: \(ids.isEmpty ? "none" : ids.map(String.init).joined(separator: ", ")). Add --window-id or a more exact selector."
		}
		throw refusal(found.isEmpty ? "No dialog matched the selected target." : "Dialog target is ambiguous across \(found.count) eligible dialogs.", hint: hint)
	}
	return (found[0], generation)
}

private func buttons(_ dialog: AXUIElement, budget: Budget) throws -> [AXUIElement] {
	try collect(dialog, roles: ["AXButton"], budget: budget)
}

private func textFields(_ dialog: AXUIElement, budget: Budget) throws -> [AXUIElement] {
	try collect(dialog, roles: ["AXTextField", "AXTextArea"], budget: budget)
}

private func isFileDialog(_ dialog: AXUIElement, budget: Budget) throws -> Bool {
	let evidence = Evidence(
		role: text(dialog, kAXRoleAttribute) ?? "", subrole: text(dialog, kAXSubroleAttribute) ?? "",
		roleDescription: text(dialog, kAXRoleDescriptionAttribute) ?? "", identifier: text(dialog, kAXIdentifierAttribute) ?? "",
		title: text(dialog, kAXTitleAttribute) ?? "")
	if evidence.isFileDialog { return true }
	let found = try buttons(dialog, budget: budget)
	let titles = Set(found.compactMap { text($0, kAXTitleAttribute)?.lowercased() })
	let identifiers = Set(found.compactMap { text($0, kAXIdentifierAttribute) })
	let hasCancel = titles.contains("cancel") || identifiers.contains("CancelButton")
	let hasPrimary = ["save", "open", "choose", "replace", "export", "import"].contains { titles.contains($0) } || identifiers.contains("OKButton")
	return hasCancel && hasPrimary
}

extension Mac {
	/// A rectangle as the native client's Bounds encodes it.
	public static func boundsJSON(_ rect: CGRect) -> JSON {
		.object([("x", JSON(Double(rect.origin.x))), ("y", JSON(Double(rect.origin.y))),
		         ("width", JSON(Double(rect.width))), ("height", JSON(Double(rect.height)))])
	}
}

/// Peekaboo's normalization of a requested button title.
private func normalized(_ title: String) -> String {
	title.trimmingCharacters(in: .whitespacesAndNewlines)
		.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").lowercased()
}

/// Whether `retained` is still in the window's tree, following sheets and children.
private func presence(_ retained: AXUIElement, in root: AXUIElement) -> Bool? {
	var visited: Set<Node> = []
	var stack = [root]
	var readable = true
	while let element = stack.popLast() {
		guard visited.insert(Node(element: element)).inserted else { continue }
		if CFEqual(element, retained) { return true }
		var combined: [AXUIElement] = []
		var seen: Set<Node> = []
		for name in ["AXSheets", kAXChildrenAttribute] {
			let (error, value) = copy(element, name)
			switch error {
			case .success:
				guard let list = value as? [AXUIElement] else {
					readable = false
					continue
				}
				combined += list.filter { seen.insert(Node(element: $0)).inserted }
			case .attributeUnsupported, .noValue: break
			default: readable = false
			}
		}
		stack.append(contentsOf: combined.reversed())
	}
	return readable ? false : nil
}

/// Whether WindowServer still lists the window for its owner: true, false, or nil when unreadable.
private func windowServerPresence(_ id: Int, pid: pid_t) -> Bool? {
	guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]] else { return nil }
	guard let row = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == id }) else { return false }
	guard let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
	return owner == pid
}

/// Whether the dialog is still present: false once its window or the dialog element is gone.
private func dialogPresent(_ candidate: Candidate, pid: pid_t) -> Bool? {
	switch windowServerPresence(candidate.window.id, pid: pid) {
	case false: return false
	case nil: return nil
	default: break
	}
	guard let window = axWindows(pid)[candidate.window.id] else { return nil }
	return presence(candidate.dialog, in: window)
}

private func targetDetails(_ pid: pid_t, _ generation: UInt64, _ windowID: Int) -> [(String, String)] {
	[("pid", String(pid)), ("process_start_identity", String(generation)), ("process_start_identity_decimal", String(generation)),
	 ("window_id", String(windowID))]
}

/// Runs AXPress on its own thread, reporting delivery when the press returns or after a 2 second grace,
/// since a press that opens a modal loop doesn't return until it ends. Ported from DetachedAXActionRunner (MIT).
private struct PressFailed: Error { let error: AXError }

private func detachedPress(_ element: AXUIElement) -> Result<Delivery, PressFailed> {
	final class Box: @unchecked Sendable {
		let element: AXUIElement
		let done = DispatchSemaphore(value: 0)
		var error: AXError = .success
		init(_ element: AXUIElement) { self.element = element }
	}
	let box = Box(element)
	Thread.detachNewThread {
		box.error = AXUIElementPerformAction(box.element, kAXPressAction as CFString)
		box.done.signal()
	}
	guard box.done.wait(timeout: .now() + 2) == .success else {
		return .success(Delivery(state: .dispatchedUnverified, mechanism: "accessibility_action", evidence: "operation_still_running", units: 1))
	}
	return box.error == .success ? .success(.accepted("accessibility_action")) : .failure(PressFailed(error: box.error))
}

extension Mac {
	/// Reads the one dialog the target selects.
	public static func dialog(pid: pid_t, windowID: Int?, windows: [DialogWindow]) throws -> DialogRead {
		let (candidate, generation) = try onlyCandidate(pid: pid, windowID: windowID, windows: windows, structuralOnly: false)
		let dialog = candidate.dialog
		let budget = Budget()
		let file = try isFileDialog(dialog, budget: budget)
		let info: JSON = .object([
			"title": JSON(text(dialog, kAXTitleAttribute) ?? "Untitled Dialog"),
			"role": JSON(text(dialog, kAXRoleAttribute) ?? "Unknown"),
			"subrole": text(dialog, kAXSubroleAttribute).map(JSON.string),
			"is_file_dialog": JSON(file),
			"bounds": Mac.boundsJSON(AX.frame(dialog) ?? .zero),
		])
		let buttonRows = try buttons(dialog, budget: budget).compactMap { button -> (String, Bool, Bool)? in
			guard let title = text(button, kAXTitleAttribute) else { return nil }
			return (title, flag(button, kAXEnabledAttribute) ?? true, flag(button, "AXDefault") ?? false)
		}
		let fieldRows = try textFields(dialog, budget: budget).enumerated().map { index, field in
			(index, text(field, kAXTitleAttribute), text(field, kAXValueAttribute), text(field, "AXPlaceholderValue"),
			 flag(field, kAXEnabledAttribute) ?? true)
		}
		let statics = try collect(dialog, roles: ["AXStaticText"], structuralTextOnly: true, budget: budget).compactMap { element in
			[kAXValueAttribute, kAXTitleAttribute, "AXLabel", kAXDescriptionAttribute].compactMap { text(element, $0) }
				.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		}
		let excluded: Set = ["AXButton", "AXTextField", "AXTextArea", "AXStaticText"]
		let others = children(dialog, strict: false).filter { !excluded.contains(text($0, kAXRoleAttribute) ?? "") }.compactMap { element -> JSON? in
			guard let role = text(element, kAXRoleAttribute) else { return nil }
			return .object(["role": JSON(role), "title": text(element, kAXTitleAttribute).map(JSON.string), "value": text(element, kAXValueAttribute).map(JSON.string)])
		}
		let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
		return DialogRead(window: candidate.window, generation: generation, applicationName: name, dialog: info,
		                  buttons: buttonRows, fields: fieldRows, staticTexts: statics, others: .array(others), isFileDialog: file)
	}

	/// Presses the one enabled AXPress button whose normalized title matches, then waits up to 0.75 seconds for
	/// the dialog to go. Throws Refusal before the press and DialogUnconfirmed after it.
	public static func pressDialogButton(pid: pid_t, windowID: Int?, windows: [DialogWindow], title: String) throws -> DialogAnswer {
		let (candidate, generation) = try onlyCandidate(pid: pid, windowID: windowID, windows: windows, structuralOnly: true)
		let budget = Budget()
		let all = try buttons(candidate.dialog, budget: budget)
		let wanted = normalized(title)
		let matches = all.filter { button in
			guard flag(button, kAXEnabledAttribute) == true, Mac.actions(button).contains(kAXPressAction) else { return false }
			if wanted == "default" { return text(button, kAXIdentifierAttribute) == "OKButton" }
			return text(button, kAXTitleAttribute).map(normalized) == wanted
		}
		guard matches.count == 1 else {
			let available = all.enumerated().map { "\($0):\(text($1, kAXTitleAttribute) ?? "untitled")" }.joined(separator: ", ")
			throw refusal(matches.isEmpty ? "No unique enabled AXPress dialog button matched the request." : "Dialog button selection is ambiguous across \(matches.count) exact matches.",
			              hint: "Candidate window ID: \(candidate.window.id). Available buttons: \(available.isEmpty ? "none" : available). Run dialog list and provide one unique exact button name.")
		}
		let button = matches[0]
		var details = targetDetails(pid, generation, candidate.window.id)
		details += [("button", text(button, kAXTitleAttribute) ?? title), ("method", "button")]
		if let identifier = text(button, kAXIdentifierAttribute), !identifier.isEmpty { details.append(("button_identifier", identifier)) }
		AXUIElementSetMessagingTimeout(button, 0)
		let leaf: Delivery
		switch detachedPress(button) {
		case let .success(delivery): leaf = delivery
		case let .failure(error):
			throw DialogUnconfirmed(
				delivery: Delivery(state: .indeterminate, mechanism: "accessibility_action", evidence: "completion_unknown", units: 1),
				message: "Dialog AXPress returned without reliable completion evidence.", details: [("cause", String(describing: error.error))])
		}
		let deadline = Date().addingTimeInterval(0.75)
		var present: Bool?
		repeat {
			present = dialogPresent(candidate, pid: pid)
			if present == false {
				return DialogAnswer(delivery: Delivery(state: .confirmedChange, mechanism: "accessibility_action", evidence: "verified_change", units: 1),
				                    details: details, windowID: candidate.window.id)
			}
			if Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
		} while Date() < deadline
		throw DialogUnconfirmed(
			delivery: leaf,
			message: present == true ? "Dialog AXPress was accepted, but the same dialog remained present."
				: "Dialog AXPress was accepted, but dialog disappearance was unreadable.",
			details: details)
	}

	/// Replaces one dialog text field's value through AXValue, in the background, and reads it back.
	public static func enterDialogText(pid: pid_t, windowID: Int?, windows: [DialogWindow], field index: Int, text value: String) throws -> DialogAnswer {
		let (candidate, generation) = try onlyCandidate(pid: pid, windowID: windowID, windows: windows, structuralOnly: true)
		do {
			return try enterText(candidate, pid: pid, generation: generation, field: index, text: value)
		} catch let refusal as Refusal {
			throw DialogRefusal(refusal: refusal, windowID: candidate.window.id)
		} catch var failure as DialogUnconfirmed {
			failure.windowID = candidate.window.id
			throw failure
		}
	}

	private static func enterText(_ candidate: Candidate, pid: pid_t, generation: UInt64, field index: Int, text value: String) throws -> DialogAnswer {
		let budget = Budget()
		let fields = try textFields(candidate.dialog, budget: budget)
		guard !fields.isEmpty else { throw refusal("The exact dialog contains no text fields.", hint: "List the exact dialog again before retrying.") }
		guard fields.indices.contains(index) else {
			throw refusal("Dialog text field index \(index) is unavailable.", hint: "List the exact dialog and provide one current field index.")
		}
		let field = fields[index]
		guard text(field, kAXRoleAttribute) != "AXSecureTextField", text(field, kAXSubroleAttribute) != "AXSecureTextField" else {
			throw refusal("Exact background dialog input cannot set a secure text field through Accessibility.",
			              hint: "Use an explicitly foreground input workflow for secure text.", reason: "operation_unsupported")
		}
		guard Mac.settable(field, kAXValueAttribute) else {
			throw refusal("The exact dialog field does not expose a settable AXValue.",
			              hint: "Choose a settable text field or use an explicitly foreground input workflow.", reason: "operation_unsupported")
		}
		func range() -> CFRange? {
			guard let raw = copy(field, kAXSelectedTextRangeAttribute).1, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
			var range = CFRange()
			return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
		}
		func same(_ a: CFRange?, _ b: CFRange?) -> Bool { a?.location == b?.location && a?.length == b?.length }
		let current = copy(field, kAXValueAttribute).1 as? String
		let selected = range()
		var cursor = CFRange(location: (value as NSString).length, length: 0)
		let valueNeedsUpdate = current != value
		let cursorNeedsUpdate = !same(selected, cursor)
		var details = targetDetails(pid, generation, candidate.window.id)
		let identifier = [text(candidate.dialog, kAXRoleAttribute) ?? "unknown", text(candidate.dialog, kAXSubroleAttribute) ?? "",
		                  text(candidate.dialog, kAXIdentifierAttribute) ?? "", text(candidate.dialog, kAXTitleAttribute) ?? "Untitled Dialog"]
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "|")
		details += [
			("dialog_identifier", identifier), ("dialog_role", text(candidate.dialog, kAXRoleAttribute) ?? "Unknown"),
			("dialog_title", text(candidate.dialog, kAXTitleAttribute) ?? "Untitled Dialog"), ("field", text(field, kAXTitleAttribute) ?? "Text Field"),
			("text_length", String(value.count)), ("cleared", "true"), ("value_verified", "true"), ("auto_focus", "true"),
			("focus_timeout_seconds", "5.0"), ("focus_retry_count", "3"), ("switch_space", "false"), ("bring_to_current_space", "false"),
			("delivery_mode", "background"), ("delivery_mechanism", "accessibility_value"), ("focus_applied", "false"),
		]
		guard valueNeedsUpdate || cursorNeedsUpdate else {
			details.append(("cursor_updated", "false"))
			return DialogAnswer(delivery: Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil),
			                    details: details, windowID: candidate.window.id)
		}
		if cursorNeedsUpdate, !Mac.settable(field, kAXSelectedTextRangeAttribute) {
			throw refusal("The exact dialog field cannot establish its required cursor range through Accessibility.",
			              hint: "Use an explicitly foreground input workflow for this field.", reason: "operation_unsupported")
		}
		let unconfirmed = Delivery(state: .indeterminate, mechanism: "accessibility_value", evidence: "completion_unknown", units: 1)
		var units = 0
		if valueNeedsUpdate {
			guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success else {
				throw DialogUnconfirmed(delivery: unconfirmed, message: "Background dialog AXValue delivery returned without acceptance evidence.", details: details)
			}
			units = 1
		}
		if cursorNeedsUpdate {
			guard let axRange = AXValueCreate(.cfRange, &cursor),
			      AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, axRange) == .success
			else {
				throw DialogUnconfirmed(delivery: Delivery(state: .indeterminate, mechanism: "accessibility_value", evidence: "completion_unknown", units: units + 1),
				                        message: "Dialog AXValue changed, but cursor placement returned without acceptance evidence.", details: details)
			}
			units += 1
		}
		let accepted = Delivery(state: .dispatchedUnverified, mechanism: "accessibility_value", evidence: "delivery_accepted", units: units)
		guard presence(field, in: candidate.dialog) == true else {
			throw DialogUnconfirmed(delivery: accepted, message: "Background dialog input was accepted, but its exact target changed during verification.", details: details)
		}
		guard copy(field, kAXValueAttribute).1 as? String == value else {
			throw DialogUnconfirmed(delivery: accepted, message: "Background dialog input was accepted, but the retained AXValue did not match.", details: details)
		}
		if cursorNeedsUpdate, !same(range(), cursor) {
			throw DialogUnconfirmed(delivery: accepted, message: "Background dialog input was accepted, but its cursor range did not match.", details: details)
		}
		details.append(("cursor_updated", String(cursorNeedsUpdate)))
		return DialogAnswer(delivery: accepted, details: details, windowID: candidate.window.id)
	}
}
