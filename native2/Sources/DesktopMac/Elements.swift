import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// The read-only Accessibility walk behind desktop_inspect, ported from Peekaboo's DetachedAXObservationWorker
// (MIT) so element IDs, types, labels and attributes match what agents already see.

/// The traversal limits for one inspection.
public struct ElementBudget: Sendable {
	public var maxDepth = 15
	public var maxElements = 200
	public var maxChildren = 100
	public var seconds: Double = 15
	public init() {}
}

/// One emitted element, with the live reference later actions resolve it by.
public struct Element: @unchecked Sendable {
	public let id: String
	public let type: String
	public let label: String?
	public let value: String?
	public let frame: CGRect
	public let isEnabled: Bool
	public let isSelected: Bool?
	public internal(set) var attributes: [String: String]
	public let reference: AXUIElement
}

public struct ElementTree: @unchecked Sendable {
	public var elements: [Element] = []
	public var windowTitle: String?
	/// The element keyboard input reaches: the one the walk saw focused, or among several, the one the app names.
	public var focusedID: String?
	public var maxDepthReached = false
	public var maxElementCountReached = false
	public var maxChildrenPerNodeReached = false
	public var deadlineReached = false
	public var incompleteAccessibilityRead = false

	public init() {}

	public var truncated: Bool {
		maxDepthReached || maxElementCountReached || maxChildrenPerNodeReached || deadlineReached || incompleteAccessibilityRead
	}

	/// Peekaboo's `ax_truncated_*` warning names.
	public var warnings: [String] {
		var names: [String] = []
		if maxDepthReached { names.append("ax_truncated_depth") }
		if maxElementCountReached { names.append("ax_truncated_count") }
		if maxChildrenPerNodeReached { names.append("ax_truncated_children") }
		if deadlineReached { names.append("ax_truncated_deadline") }
		if incompleteAccessibilityRead { names.append("ax_truncated_incomplete") }
		return names
	}
}

private let descriptorNames = [
	kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, "AXLabel",
	kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute, kAXIdentifierAttribute,
	kAXEnabledAttribute, kAXSelectedAttribute, kAXFocusedAttribute, "AXPlaceholderValue", "AXEditable", "AXKeyboardShortcut",
]
private let childNames = [
	kAXChildrenAttribute, "AXVisibleChildren", "AXWebAreaChildren", "AXApplicationNavigation", "AXApplicationElements",
	"AXBodyArea", "AXSplitGroupContents", "AXLayoutAreaChildren", "AXGroupChildren", "AXContents",
	"AXChildrenInNavigationOrder", kAXSelectedChildrenAttribute, kAXRowsAttribute, kAXColumnsAttribute, "AXTabs",
]
private let actionableRoles: Set<String> = [
	"axbutton", "axpopupbutton", "axtextfield", "axtextarea", "axsearchfield", "axsecuretextfield",
	"axlink", "axweblink", "axcheckbox", "axradiobutton", "axmenuitem", "axcombobox", "axslider", "axtab",
]
private let actionLookupRoles: Set<String> = ["axgroup", "aximage", "axcell", "axrow", "axoutlineitem"]
private let valueMetadataRoles: Set<String> = [
	"axcheckbox", "axcombobox", "axdatefield", "axdatetimearea", "axtimefield", "axincrementor", "axpopupbutton",
	"axradiobutton", "axscrollbar", "axsearchfield", "axsecuretextfield", "axslider", "axswitch", "axtextarea", "axtextfield",
]
private let identityNames: Set<String> = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
private let textFieldKeywords = ["email", "password", "username", "phone", "code"]
/// Element types in the order Peekaboo groups `ui_elements`.
public let elementTypeOrder = ["button", "textField", "link", "image", "group", "slider", "checkbox", "menu", "other"]

private func embeddedError(_ value: Any) -> AXError? {
	let cf = value as CFTypeRef
	guard CFGetTypeID(cf) == AXValueGetTypeID(), AXValueGetType(cf as! AXValue) == .axError else { return nil }
	var error = AXError.success
	return AXValueGetValue(cf as! AXValue, .axError, &error) ? error : .failure
}

/// Apps answer inapplicable optional attributes with a generic failure, so only a hard error on role or frame,
/// or one proving the read itself didn't finish, makes a node unreadable.
private func invalidatesNode(_ error: AXError, _ attribute: String) -> Bool {
	guard AX.incomplete(error) else { return false }
	return error != .failure || identityNames.contains(attribute)
}

private func unsupported(_ error: AXError) -> Bool {
	error == .attributeUnsupported || error == .parameterizedAttributeUnsupported || error == .notImplemented
}

private func boolValue(_ value: Any?) -> Bool? {
	if let bool = value as? Bool { return bool }
	return (value as? NSNumber)?.boolValue
}

private func displayValue(_ value: Any?) -> String? {
	if let string = value as? String { return string }
	if let date = value as? Date {
		guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
		return date.ISO8601Format(.init(includingFractionalSeconds: true))
	}
	guard let value else { return nil }
	let cf = value as CFTypeRef
	if CFGetTypeID(cf) == CFBooleanGetTypeID() { return (value as? NSNumber)?.boolValue == true ? "true" : "false" }
	if CFGetTypeID(cf) == CFNumberGetTypeID(), let number = value as? NSNumber { return number.stringValue }
	return nil
}

private func normalize(_ value: String?) -> String? {
	guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
	return trimmed
}

private struct Descriptor {
	let frame: CGRect
	let role: String
	let isSecure: Bool
	let title, label, value, description, help, roleDescription, identifier: String?
	let isEnabled, isSelected, isFocused: Bool?
	let placeholder: String?
	let isEditable: Bool
	let keyboardShortcut: String?

	init(_ values: [String: Any]) {
		frame = CGRect(origin: AX.point(values[kAXPositionAttribute] as CFTypeRef?) ?? .zero,
		               size: AX.size(values[kAXSizeAttribute] as CFTypeRef?) ?? .zero)
		role = values[kAXRoleAttribute] as? String ?? "Unknown"
		isSecure = role == "AXSecureTextField" || values[kAXSubroleAttribute] as? String == "AXSecureTextField"
		title = values[kAXTitleAttribute] as? String
		label = values["AXLabel"] as? String
		// A secure field's value is a mask, one character per secret character, so even it is never kept.
		value = isSecure ? nil : displayValue(values[kAXValueAttribute])
		description = values[kAXDescriptionAttribute] as? String
		help = values[kAXHelpAttribute] as? String
		roleDescription = values[kAXRoleDescriptionAttribute] as? String
		identifier = values[kAXIdentifierAttribute] as? String
		isEnabled = boolValue(values[kAXEnabledAttribute])
		let lowered = role.lowercased()
		isSelected = boolValue(values[kAXSelectedAttribute])
			?? (["axcheckbox", "axradiobutton", "axswitch"].contains(lowered) ? boolValue(values[kAXValueAttribute]) : nil)
		isFocused = boolValue(values[kAXFocusedAttribute])
		placeholder = values["AXPlaceholderValue"] as? String
		isEditable = boolValue(values["AXEditable"]) ?? false
		keyboardShortcut = values["AXKeyboardShortcut"] as? String
	}

	var type: String {
		let lowered = role.lowercased()
		var type = switch lowered {
		case "axbutton", "axpopupbutton": "button"
		case "axtextfield", "axtextarea", "axsearchfield", "axsecuretextfield": "textField"
		case "axlink", "axweblink": "link"
		case "aximage": "image"
		case "axcheckbox", "axradiobutton": "checkbox"
		case "axslider": "slider"
		case "axmenu", "axmenubar": "menu"
		case "axgroup" where isEditable: "textField"
		case "axgroup": "group"
		default: "other"
		}
		if type == "group", let text = roleDescription?.lowercased(),
		   text.contains("text field") || text.contains("text input") || text.contains("search field")
		{
			type = "textField"
		}
		// Frameworks that flatten an input into a group or static text leave these hints behind.
		let recoverable = type == "group" || (type == "other" && role.caseInsensitiveCompare("AXStaticText") == .orderedSame && placeholder?.isEmpty == false)
		if recoverable {
			let hinted = placeholder?.isEmpty == false
				|| [title, label].contains { text in text.map { text in textFieldKeywords.contains { text.lowercased().contains($0) } } ?? false }
			if hinted { type = "textField" }
		}
		return type
	}

	var resolvedLabel: String? {
		let base = [label, title, description, placeholder, value, roleDescription]
			.lazy.compactMap(normalize).first { $0.lowercased() != "button" }
		guard role.lowercased() == "axbutton", base == nil else { return base }
		return normalize(identifier).map { $0.replacingOccurrences(of: "-button", with: "").replacingOccurrences(of: "-", with: " ") }
	}
}

/// Standard action names only, bounded; custom actions carry arbitrary app text and are omitted.
private func standardActions(_ actions: [String]) -> String? {
	var names: [String] = []
	for action in actions where names.count < 16 {
		guard action.hasPrefix("AX"), action.utf8.count <= 48,
		      action.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }), !names.contains(action)
		else { continue }
		names.append(action)
	}
	return names.isEmpty ? nil : names.joined(separator: ",")
}

private struct Walk {
	let deadline: ContinuousClock.Instant
	let budget: ElementBudget
	var tree = ElementTree()
	var visited: [AXUIElement] = []
	var columnHeaders: [AXUIElement] = []
	/// Only Notification Center's custom action names are listed; elsewhere they are arbitrary app text.
	var listsCustomActions = false

	func timeout() -> Float? {
		let remaining = ContinuousClock.now.duration(to: deadline)
		let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
		return seconds > 0 ? Float(min(0.2, seconds)) : nil
	}

	/// nil means traverse only; `incomplete` means the read gave up.
	func descriptor(_ element: AXUIElement) -> (Descriptor?, incomplete: Bool) {
		var raw: CFArray?
		let error = AXUIElementCopyMultipleAttributeValues(element, descriptorNames as CFArray, [], &raw)
		var byName: [String: Any] = [:]
		if error == .success {
			guard let values = raw as? [Any], values.count == descriptorNames.count else { return (nil, true) }
			for (name, value) in zip(descriptorNames, values) {
				if let embedded = embeddedError(value) {
					if invalidatesNode(embedded, name) { return (nil, true) }
					continue
				}
				byName[name] = value
			}
		} else if unsupported(error) {
			for name in descriptorNames {
				var value: CFTypeRef?
				let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
				if invalidatesNode(error, name) { return (nil, true) }
				if let value { byName[name] = value }
			}
		} else {
			return (nil, true)
		}
		let descriptor = Descriptor(byName)
		guard descriptor.frame.width > 5, descriptor.frame.height > 5 else { return (nil, false) }
		return (descriptor, false)
	}

	func children(_ element: AXUIElement) -> (elements: [AXUIElement], incomplete: Bool) {
		var raw: CFArray?
		let error = AXUIElementCopyMultipleAttributeValues(element, childNames as CFArray, [], &raw)
		let values = raw as? [Any]
		let usable = error == .success && values?.count == childNames.count
			&& !(values ?? []).contains { embeddedError($0).map(AX.incomplete) ?? false }
		guard usable, let values else {
			var value: CFTypeRef?
			let single = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
			return (value as? [AXUIElement] ?? [], !unsupported(error) || AX.incomplete(single))
		}
		var result: [AXUIElement] = []
		for value in values {
			for child in value as? [AXUIElement] ?? [] where !result.contains(where: { CFEqual($0, child) }) {
				result.append(child)
			}
		}
		return (result, false)
	}

	mutating func process(_ element: AXUIElement, depth: Int) {
		guard ContinuousClock.now < deadline else { tree.deadlineReached = true; return }
		guard depth < budget.maxDepth else { tree.maxDepthReached = true; return }
		guard tree.elements.count < budget.maxElements else { tree.maxElementCountReached = true; return }
		guard !visited.contains(where: { CFEqual($0, element) }) else { return }
		visited.append(element)
		AXUIElementSetMessagingTimeout(element, timeout() ?? 0.01)

		let (read, incomplete) = descriptor(element)
		if incomplete { tree.incompleteAccessibilityRead = true }
		if let descriptor = read, !incomplete { emit(descriptor, element, depth: depth) }
		processChildren(element, depth: depth)
	}

	mutating func emit(_ descriptor: Descriptor, _ element: AXUIElement, depth: Int) {
		let role = descriptor.role.lowercased()
		let baseType = role == "axgroup" ? (descriptor.isEditable ? "textField" : "group") : nil
		let type = descriptor.type
		var identifier = descriptor.identifier
		if baseType != "textField", type == "textField", let id = identifier, id.hasPrefix("group-"), id.count > 6 {
			identifier = String(id.dropFirst(6))
		}
		var names: CFArray?
		let actions = AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
		let exposes = actionableRoles.contains(role) || (actionLookupRoles.contains(role) && actions.contains(kAXPressAction))
		var settable: Bool?
		if type == "textField" || valueMetadataRoles.contains(role), let timeout = timeout() {
			AXUIElementSetMessagingTimeout(element, timeout)
			var value = DarwinBoolean(false)
			if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &value) == .success { settable = value.boolValue }
		}
		let id = "elem_\(tree.elements.count)"
		var attributes = ["role": descriptor.role, "axEnabledKnown": String(descriptor.isEnabled != nil)]
		attributes["title"] = descriptor.title
		attributes["description"] = descriptor.description
		attributes["help"] = descriptor.help
		attributes["roleDescription"] = descriptor.roleDescription
		if descriptor.isSecure { attributes["subrole"] = "AXSecureTextField" }
		attributes["identifier"] = identifier
		attributes["placeholder"] = descriptor.placeholder
		attributes["keyboardShortcut"] = descriptor.keyboardShortcut
		if exposes || settable == true { attributes["isActionable"] = "true" }
		attributes["isValueSettable"] = settable.map { String($0) }
		attributes["isFocused"] = descriptor.isFocused.map { String($0) }
		attributes["actions"] = standardActions(actions)
		if listsCustomActions { attributes["customActions"] = CustomActions.attribute(actions) }
		if role == "axtable" {
			// A web table names its header cells here; their role description no longer says so on macOS 27.
			if let headers = AX.value(element, "AXColumnHeaderUIElements") as? [AXUIElement] {
				columnHeaders.append(contentsOf: headers.prefix(64))
			}
		} else if role == "axcell", columnHeaders.contains(where: { CFEqual($0, element) }) {
			attributes["columnHeader"] = "true"
		}
		if role == "axrow" {
			// Outline rows are flat siblings; only their disclosure level shows the hierarchy.
			if let level = AX.value(element, "AXDisclosureLevel") as? NSNumber, CFGetTypeID(level) != CFBooleanGetTypeID(),
			   (0...1000).contains(level.intValue)
			{
				attributes["disclosureLevel"] = String(level.intValue)
			}
			if let disclosing = boolValue(AX.value(element, "AXDisclosing")) { attributes["disclosing"] = String(disclosing) }
		}
		attributes["depth"] = String(depth)
		tree.elements.append(Element(
			id: id, type: type, label: descriptor.resolvedLabel, value: descriptor.value, frame: descriptor.frame,
			isEnabled: descriptor.isEnabled ?? false, isSelected: descriptor.isSelected, attributes: attributes, reference: element
		))
	}

	mutating func processChildren(_ element: AXUIElement, depth: Int) {
		let read = children(element)
		if read.incomplete { tree.incompleteAccessibilityRead = true }
		if read.elements.count > budget.maxChildren { tree.maxChildrenPerNodeReached = true }
		let limited = read.elements.prefix(budget.maxChildren)
		for (index, child) in limited.enumerated() {
			process(child, depth: depth + 1)
			guard index < limited.count - 1 else { break }
			if tree.elements.count >= budget.maxElements { tree.maxElementCountReached = true; return }
			if ContinuousClock.now >= deadline { tree.deadlineReached = true; return }
		}
	}
}

extension Mac {
	/// Walks one exact window's Accessibility tree. Throws when Accessibility doesn't list that window.
	public static func elements(pid: pid_t, windowID: Int, budget: ElementBudget = ElementBudget()) throws -> ElementTree {
		let deadline = ContinuousClock.now + .seconds(budget.seconds - min(0.25, max(0.01, budget.seconds * 0.1)))
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, 0.2)
		var raw: CFTypeRef?
		let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
		let windows = (raw as? [AXUIElement] ?? []).filter { AX.windowID($0) == windowID }
		guard windows.count == 1, let window = windows.first else {
			if error == .apiDisabled || !AXIsProcessTrusted() {
				throw ToolError("permissionDenied: Accessibility access is off for the Desktop Tools host.")
			}
			// Still in WindowServer but not in Accessibility, as a web view's window is while it loads.
			throw ToolError("internalError: Exact window \(windowID) returned no usable Accessibility elements. Warning: AX tree incomplete at incomplete accessibility read. Retry once after a short wait.")
		}
		// Read before the walk so a focus change during it can't be taken for the focus the walk saw.
		AXUIElementSetMessagingTimeout(app, 0.05)
		let focusBefore = AX.value(app, kAXFocusedUIElementAttribute).flatMap {
			CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
		}
		var walk = Walk(deadline: deadline, budget: budget)
		walk.listsCustomActions = CustomActions.isNotificationCenter(pid)
		walk.tree.windowTitle = AX.string(window, kAXTitleAttribute)
		walk.process(window, depth: 0)
		if walk.tree.elements.isEmpty {
			throw ToolError("internalError: Exact window \(windowID) returned no usable Accessibility elements. Warning: AX tree incomplete at incomplete accessibility read. Retry once after a short wait.")
		}
		walk.tree.focusedID = focusedID(walk.tree, app: app, before: focusBefore)
		if !walk.tree.truncated { attachSelection(&walk.tree) }
		return walk.tree
	}

	/// Peekaboo's focus receipt: the one element that says it has focus. Several can, as a focused table's cells
	/// do, and then only a complete walk names one: the app's focused element, unchanged since before the walk.
	static func focusedID(_ tree: ElementTree, app: AXUIElement, before: AXUIElement?) -> String? {
		let focused = tree.elements.filter { $0.attributes["isFocused"] == "true" }
		if focused.count == 1 { return focused[0].id }
		guard focused.count > 1, !tree.incompleteAccessibilityRead, !tree.deadlineReached, let before else { return nil }
		AXUIElementSetMessagingTimeout(app, 0.2)
		guard let raw = AX.value(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID()
		else { return nil }
		let current = raw as! AXUIElement
		guard CFEqual(before, current) else { return nil }
		let matches = focused.filter { CFEqual($0.reference, current) }
		return matches.count == 1 ? matches[0].id : nil
	}

	/// The focused text field's selection, which a complete walk records for its focus receipt when that element
	/// still has focus when read again.
	static func attachSelection(_ tree: inout ElementTree) {
		guard let id = tree.focusedID, let index = tree.elements.firstIndex(where: { $0.id == id }) else { return }
		let element = tree.elements[index]
		guard element.type == "textField", element.attributes["subrole"] != "AXSecureTextField" else { return }
		AXUIElementSetMessagingTimeout(element.reference, 0.2)
		guard (AX.value(element.reference, kAXFocusedAttribute) as? Bool) == true,
		      let raw = AX.value(element.reference, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID()
		else { return }
		var range = CFRange()
		guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return }
		tree.elements[index].attributes["selectedTextRangeLocation"] = String(range.location)
		tree.elements[index].attributes["selectedTextRangeLength"] = String(range.length)
	}
}
