import AppKit
import ApplicationServices
import DesktopProtocol
import Foundation

// App menus, ported from Peekaboo's MenuService+List, MenuService+Models and MenuCommand (MIT): the listing walks
// the menu bar's Accessibility tree without opening anything, and a command presses one exact leaf in the background.

/// One row of desktop_menus: a literal title path, its kind and its shortcut as Peekaboo displays it.
public struct MenuRow: Sendable {
	public let path: [String]
	public let kind: String
	public let shortcut: String?
}

public struct MenuStructure: Sendable {
	public let applicationName: String
	public let bundleID: String?
	public let rows: [MenuRow]
}

/// Peekaboo's balanced traversal limits: depth, items visited and seconds.
private struct MenuBudget {
	let maxDepth = 8
	let maxChildren = 500
	let seconds: TimeInterval = 3
	let started = Date()
	var visited = 0

	mutating func allow(depth: Int) -> Bool {
		guard Date().timeIntervalSince(started) <= seconds, depth <= maxDepth, visited < maxChildren else { return false }
		visited += 1
		return true
	}
}

/// Peekaboo keeps a listing for two seconds; a command on the app drops it.
private final class MenuCache: @unchecked Sendable {
	private let lock = NSLock()
	private var entries: [pid_t: (expires: Date, structure: MenuStructure)] = [:]
	func get(_ pid: pid_t) -> MenuStructure? {
		lock.withLock { entries[pid].flatMap { $0.expires > Date() ? $0.structure : nil } }
	}
	func put(_ pid: pid_t, _ structure: MenuStructure) { lock.withLock { entries[pid] = (Date().addingTimeInterval(2), structure) } }
	func drop(_ pid: pid_t) { _ = lock.withLock { entries.removeValue(forKey: pid) } }
}

private let menuCache = MenuCache()

private func children(_ element: AXUIElement) -> [AXUIElement] {
	AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

extension Mac {
	/// Whether `pid` is a running app of generation `generation`, as the application inventory would list it.
	public static func isRunning(_ pid: pid_t, generation: UInt64) -> Bool {
		guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
		return startIdentity(pid).value == generation
	}

	/// One app's menu bar as rows, from a cached listing when one is under two seconds old.
	public static func menus(pid: pid_t) throws -> MenuStructure {
		if let cached = menuCache.get(pid) { return cached }
		guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
			throw ToolError("DESKTOP_ERROR: Application 'PID:\(pid)' not found.")
		}
		let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
		let element = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(element, 2)
		guard let bar = AX.element(AX.value(element, kAXMenuBarAttribute)) else {
			throw ToolError("DESKTOP_ERROR: Menu bar not found for application '\(name)'.")
		}
		AXUIElementSetMessagingTimeout(bar, 2)
		var budget = MenuBudget()
		var rows: [MenuRow] = []
		func items(_ elements: [AXUIElement], depth: Int, path: [String]) {
			for element in elements {
				guard budget.allow(depth: depth) else { break }
				if AX.string(element, kAXRoleAttribute) == "AXSeparatorMenuItem" {
					rows.append(MenuRow(path: path + ["---"], kind: "separator", shortcut: nil))
					continue
				}
				let title = AX.string(element, kAXTitleAttribute) ?? AX.string(element, kAXValueAttribute) ?? ""
				guard !title.isEmpty else { continue }
				rows.append(MenuRow(path: path + [title], kind: "item", shortcut: shortcut(element)))
				if depth + 1 <= budget.maxDepth, let submenu = children(element).first(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole }) {
					items(children(submenu), depth: depth + 1, path: path + [title])
				}
			}
		}
		for item in children(bar) {
			guard budget.allow(depth: 1) else { break }
			guard let title = AX.string(item, kAXTitleAttribute), budget.allow(depth: 1) else { continue }
			rows.append(MenuRow(path: [title], kind: "menu", shortcut: nil))
			if let menu = children(item).first(where: { AX.string($0, kAXRoleAttribute) == kAXMenuRole }) {
				items(children(menu), depth: 2, path: [title])
			}
		}
		let structure = MenuStructure(applicationName: name, bundleID: app.bundleIdentifier, rows: rows)
		menuCache.put(pid, structure)
		return structure
	}

	/// The shortcut as Peekaboo displays it: ⌘ unless the item says no Command, then ⇧, ⌥, ⌃ and the key.
	static func shortcut(_ element: AXUIElement) -> String? {
		guard let key = AX.string(element, kAXMenuItemCmdCharAttribute),
		      let modifiers = (AX.value(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue
		else { return nil }
		var display = ""
		if modifiers & 8 == 0 { display += "⌘" }
		if modifiers & 1 != 0 { display += "⇧" }
		if modifiers & 2 != 0 { display += "⌥" }
		if modifiers & 4 != 0 { display += "⌃" }
		return display + key.uppercased()
	}

	/// Presses the one menu item at the literal `path`, after reading its ancestry twice and checking it is an
	/// enabled leaf that takes AXPress. Throws a Refusal when nothing was sent.
	public static func menuCommand(pid: pid_t, generation: UInt64, path: [String]) throws -> Delivery {
		defer { menuCache.drop(pid) }
		guard pid != getpid() else {
			var refusal = Refusal("DESKTOP_ACTION_FAILED", "Menu commands targeting this Ace process are not supported. No menu command was dispatched.")
			refusal.reason = "operation_unsupported"
			throw refusal
		}
		let read = MenuCommandRead(pid: pid, generation: generation, path: path)
		let original = try read.resolve()
		let current = try read.resolve()
		guard original.count == current.count, zip(original, current).allSatisfy({ CFEqual($0.0, $0.1) }), let leaf = original.last else {
			throw read.refusal("The observed menu ancestry changed before input.")
		}
		guard try read.role(leaf) == kAXMenuItemRole else { throw read.refusal("Choose a menu command item, not a menu-bar entry.") }
		for child in try read.children(leaf, requireAvailable: true) {
			guard try read.role(child) != kAXMenuRole else { throw read.refusal("Choose a menu command leaf, not a menu with a submenu.") }
		}
		guard let enabled = try read.attribute(leaf, kAXEnabledAttribute), CFGetTypeID(enabled) == CFBooleanGetTypeID(), CFEqual(enabled, kCFBooleanTrue) else {
			throw read.refusal("The exact menu command is disabled or its enabled state is unavailable. Apps often disable document commands while they are not active; activate the app and read the menu path again before retrying.")
		}
		let actions: [String] = try read.withElement(leaf) {
			var value: CFArray?
			guard AXUIElementCopyActionNames(leaf, &value) == .success, let names = value as? [String], names.count <= 32 else {
				throw read.refusal("The menu command's supported actions are unavailable.")
			}
			return names
		}
		guard actions.contains(kAXPressAction) else {
			var refusal = Refusal("DESKTOP_ACTION_FAILED", "The exact menu command does not support AXPress.")
			refusal.reason = "operation_unsupported"
			throw refusal
		}
		// A Paste command would put the clipboard's text into a focused password field, as Command-V would.
		if focusIsSecure(pid), isPasteMenuItem(leaf) { throw secureFocusRefusal }
		try read.check()
		guard AXUIElementSetMessagingTimeout(leaf, 2) == .success else {
			throw read.refusal("The native menu command timeout could not be set before input.")
		}
		defer { AXUIElementSetMessagingTimeout(leaf, 0) }
		try read.checkOwner(leaf)
		try read.check()
		let result = AXUIElementPerformAction(leaf, kAXPressAction as CFString)
		if result == .success { return .accepted("accessibility_action") }
		if [.cannotComplete, .failure].contains(result) || !axClassified(result) {
			throw MenuIndeterminate(cause: String(describing: result))
		}
		var refusal = Refusal("DESKTOP_ACTION_FAILED", "The exact menu command was refused by Accessibility.", cause: String(describing: result))
		if result == .actionUnsupported { refusal.reason = "operation_unsupported" }
		throw refusal
	}

	/// Whether the app's focused element is a secure text field, as Peekaboo's SecureFieldInput reads it.
	static func focusIsSecure(_ pid: pid_t) -> Bool {
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, 1)
		guard let focused = AX.element(AX.value(app, kAXFocusedUIElementAttribute)) else { return false }
		return AX.string(focused, kAXRoleAttribute) == "AXSecureTextField" || AX.string(focused, kAXSubroleAttribute) == "AXSecureTextField"
	}

	/// Whether a menu item pastes, whatever its localized title: Command-V, or an identifier such as `paste:`.
	static func isPasteMenuItem(_ item: AXUIElement) -> Bool {
		if AX.string(item, kAXIdentifierAttribute)?.lowercased().hasPrefix("paste") == true { return true }
		guard AX.string(item, kAXMenuItemCmdCharAttribute)?.uppercased() == "V" else { return false }
		guard let flags = (AX.value(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue else { return true }
		return flags & 8 == 0
	}
}

/// AX errors Peekaboo's ActionInputDriver classifies as unsupported, stale or denied, which mean nothing happened.
private func axClassified(_ error: AXError) -> Bool {
	[.actionUnsupported, .attributeUnsupported, .parameterizedAttributeUnsupported, .invalidUIElement, .invalidUIElementObserver, .apiDisabled].contains(error)
}

/// The press may have been delivered; Accessibility couldn't say.
public struct MenuIndeterminate: Error {
	public let cause: String
}

/// Raw Accessibility reads bound to one app generation, a five-second budget and 500 siblings.
private final class MenuCommandRead {
	let pid: pid_t
	let generation: UInt64
	let path: [String]
	let deadline = Date().addingTimeInterval(5)
	let application: AXUIElement
	var remaining = 500

	init(pid: pid_t, generation: UInt64, path: [String]) {
		self.pid = pid
		self.generation = generation
		self.path = path
		application = AXUIElementCreateApplication(pid)
	}

	func refusal(_ message: String) -> Refusal {
		Refusal("DESKTOP_ACTION_FAILED", message, hint: "Read the current literal menu path; no menu command was dispatched.")
	}

	func invalid(_ message: String) -> Refusal {
		var refusal = Refusal("DESKTOP_ACTION_FAILED", message)
		refusal.reason = "invalid_request"
		return refusal
	}

	func check() throws {
		guard Date() < deadline else { throw refusal("The menu path could not be verified within its native read budget.") }
		guard Mac.generation(pid) == generation else { throw refusal("The application process generation changed before the menu command.") }
	}

	func checkOwner(_ element: AXUIElement) throws {
		guard AX.pid(element) == pid else { throw refusal("The menu element does not belong to the exact application.") }
	}

	func withElement<T>(_ element: AXUIElement, _ operation: () throws -> T) throws -> T {
		try check()
		try checkOwner(element)
		guard AXUIElementSetMessagingTimeout(element, 1) == .success else { throw refusal("The menu element's native read timeout could not be set.") }
		defer { AXUIElementSetMessagingTimeout(element, 0) }
		let result = try operation()
		try check()
		return result
	}

	func attribute(_ element: AXUIElement, _ name: String, optional: Bool = false) throws -> CFTypeRef? {
		try withElement(element) {
			var value: CFTypeRef?
			let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
			if optional, result == .noValue || result == .attributeUnsupported { return nil }
			guard result == .success, let value else { throw refusal("A required menu attribute could not be read completely.") }
			return value
		}
	}

	func role(_ element: AXUIElement) throws -> String {
		guard let role = try attribute(element, kAXRoleAttribute) as? String else { throw refusal("A menu element's role could not be verified.") }
		return role
	}

	func children(_ element: AXUIElement, requireAvailable: Bool = false) throws -> [AXUIElement] {
		try withElement(element) {
			var count: CFIndex = 0
			let status = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
			if !requireAvailable, status == .noValue || status == .attributeUnsupported { return [] }
			guard status == .success, count >= 0, count <= remaining else {
				throw refusal("The complete menu sibling set is unavailable or exceeds its budget (AX \(status.rawValue), count \(count), remaining \(remaining), leaf check \(requireAvailable)).")
			}
			if count == 0 { return [] }
			var values: CFArray?
			guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values) == .success,
			      let values, CFArrayGetCount(values) == count, let children = values as? [AXUIElement]
			else { throw refusal("The complete menu sibling set could not be read.") }
			var again: CFIndex = 0
			guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &again) == .success, again == count else {
				throw refusal("The menu sibling set changed while it was being read.")
			}
			remaining -= count
			return children
		}
	}

	func resolve() throws -> [AXUIElement] {
		guard let value = try attribute(application, kAXMenuBarAttribute), let bar = AX.element(value) else {
			throw refusal("The exact application's menu bar is unavailable.")
		}
		var menu = bar
		var chain: [AXUIElement] = [menu]
		for (index, title) in path.enumerated() {
			var matches: [AXUIElement] = []
			var candidates: [String] = []
			for child in try children(menu) {
				// Separators and known non-item roles cannot compete for this literal title.
				guard try role(child) == (index == 0 ? kAXMenuBarItemRole : kAXMenuItemRole) else { continue }
				let raw = try attribute(child, kAXTitleAttribute, optional: true)
				let rawValue = try raw ?? attribute(child, kAXValueAttribute, optional: true)
				guard let candidate = rawValue as? String else {
					throw refusal("A candidate menu title is unavailable, so its uniqueness cannot be established.")
				}
				candidates.append(candidate)
				if candidate.utf16.elementsEqual(title.utf16) { matches.append(child) }
			}
			guard matches.count == 1, let item = matches.first else {
				throw invalid(mismatch(at: index, matches: matches.count, candidates: candidates))
			}
			chain.append(item)
			if index == path.count - 1 { return chain }
			var submenus: [AXUIElement] = []
			for child in try children(item) where try role(child) == kAXMenuRole { submenus.append(child) }
			guard submenus.count == 1, let submenu = submenus.first else {
				throw refusal("The literal submenu is missing, ambiguous, or unavailable without opening it.")
			}
			chain.append(submenu)
			menu = submenu
		}
		throw refusal("The literal menu path contains no command.")
	}

	/// Names the failed component and the sibling titles already read; matching itself stays literal.
	func mismatch(at index: Int, matches: Int, candidates: [String]) -> String {
		let title = path[index]
		let place = index == 0 ? "in the menu bar" : "under \(String(reflecting: path[index - 1]))"
		let level = "level \(index + 1) of \(path.count)"
		if matches > 1 {
			return "The literal menu path is ambiguous: \(matches) items titled \(String(reflecting: title)) \(place) (\(level))."
		}
		var message = "No menu item titled \(String(reflecting: title)) \(place) (\(level))"
		let near = candidates.filter { $0.utf16.elementsEqual((title + "\u{2026}").utf16) || $0.utf16.elementsEqual((title + "...").utf16) }
		message += near.count == 1 ? "; did you mean \(String(reflecting: near[0]))?" : "."
		message += " Titles must match exactly."
		let titles = candidates.filter { !$0.isEmpty }.map { String(reflecting: $0) }
		guard !titles.isEmpty else { return message + " No titled items were read \(place)." }
		var listed: [String] = []
		var length = 0
		for quoted in titles {
			guard listed.count < 30, length + quoted.count <= 300 else { break }
			listed.append(quoted)
			length += quoted.count + 2
		}
		if listed.isEmpty { return message + " The \(titles.count) titles \(place) are too long to list." }
		let rest = titles.count - listed.count
		return message + " Titles \(place): \(listed.joined(separator: ", "))" + (rest > 0 ? ", and \(rest) more." : ".")
	}
}

extension Mac {
	/// Every window number WindowServer knows, on screen or not; taken just before an action.
	public static func windowIDs() -> Set<Int> {
		let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
		return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
	}

	/// Whether a normal-layer window of `pid` that isn't in `before` exists.
	public static func appearedWindow(pid: pid_t, before: Set<Int>) -> Bool {
		let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
		return list.contains { info in
			(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
				&& !before.contains((info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)
		}
	}
}
