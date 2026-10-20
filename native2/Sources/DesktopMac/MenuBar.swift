import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation
import ScreenCaptureKit

// Status items, ported from Peekaboo's MenuService+ExtrasMenuBar, MenuExtraWindows, MenuBarCGSBridge, its menu bar
// titles (UIAXHelpers, MenuExtraSupport) and its by-index click (MIT). Where MenuBarAgent draws the whole bar, items
// are Accessibility elements of their owners' AXExtrasMenuBar and are pressed. Elsewhere each item is a WindowServer
// window on the status layers, found as Peekaboo finds them by default, and is clicked through that window.

/// One status item, in the order desktop_menubar_items lists them.
public struct StatusItemRow: Sendable {
	public let index: Int
	public let title: String
	public let rawTitle: String?
	public let identifier: String?
	public let ownerName: String?
	public let bundleID: String?
	public let pid: pid_t
	/// The owner's generation; nil when it can't be read, so the item has no target.
	public let generation: UInt64?
	public let frame: CGRect
	public let isVisible: Bool
	/// The item's own window, where WindowServer draws it and the window still belongs to its owner.
	public let windowID: Int?
	/// ax-extras, or cgs and cgwindow for the WindowServer inventory.
	public let source: String
	/// What a click compares, as Peekaboo's selected-leaf evidence does: the item's identity and the whole set's.
	public let leaf: String
}

struct Extra {
	let pid: pid_t
	let label: String?
	let identifier: String?
	let title: String
	let ownerName: String?
	let bundleID: String?
	let frame: CGRect
	let isVisible: Bool
	let actions: [String]
	let element: AXUIElement?
	var windowID: Int? = nil
	var windowLayer: Int? = nil
	var source = "ax-extras"
}

private func sanitized(_ value: String?) -> String? {
	guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
	return trimmed
}

private func isPlaceholder(_ title: String?) -> Bool {
	guard let title = sanitized(title) else { return true }
	let lower = title.lowercased()
	if ["unknown", "item", "menu item"].contains(lower) || lower.hasPrefix("item-") || lower.hasPrefix("item ") { return true }
	if lower.hasPrefix("bentobox") || lower.hasPrefix("menubaritem") { return true }
	if title.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return true }
	return title.range(of: #"^[0-9a-fA-F\-]{8,}$"#, options: .regularExpression) != nil
}

private func normalizedTitle(_ value: String?) -> String? {
	guard let value = sanitized(value) else { return nil }
	let stripped = value.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").replacingOccurrences(of: "&", with: "")
		.replacingOccurrences(of: #"(&[A-Za-z])|⌘|Ctrl\+|Alt\+|Option\+|Shift\+|⇧|⌃|⌥|⌘"#, with: " ", options: .regularExpression)
		.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
	let collapsed = stripped.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
	return collapsed.isEmpty ? nil : collapsed
}

/// Control Center's display names for its own identifiers.
private let controlCenterNames: [String: String] = {
	guard let raw = CFPreferencesCopyAppValue("ControlCenterDisplayableChronoControlsProviderConfiguration" as CFString, "com.apple.controlcenter" as CFString)
	else { return [:] }
	let data: Data
	if let string = raw as? String { data = Data(string.utf8) } else if let value = raw as? Data { data = value } else { return [:] }
	guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let controls = json["Controls"] as? [[String: Any]] else { return [:] }
	var mapping: [String: String] = [:]
	for control in controls {
		guard let name = control["DisplayName"] as? String, let identifiers = control["Identifier"] as? [String] else { continue }
		for identifier in identifiers where mapping[identifier.uppercased()] == nil { mapping[identifier.uppercased()] = name }
	}
	return mapping
}()

private func camelCaseToWords(_ token: String) -> String {
	var result = ""
	var previousUppercase = false
	for character in token {
		if character == "_" || character == "-" {
			if !result.hasSuffix(" ") { result.append(" ") }
			previousUppercase = false
			continue
		}
		if character.isUppercase, !previousUppercase, !result.isEmpty { result.append(" ") }
		result.append(character)
		previousUppercase = character.isUppercase
	}
	return result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).capitalized
}

private func readableIdentifier(_ identifier: String?) -> String? {
	guard let identifier = sanitized(identifier) else { return nil }
	if let mapped = controlCenterNames[identifier.uppercased()] { return mapped }
	let separators = CharacterSet(charactersIn: "._-:/")
	let tokens = identifier.split { $0.unicodeScalars.contains { separators.contains($0) } }
	guard let last = tokens.last, !isPlaceholder(String(last)) else { return nil }
	let spaced = camelCaseToWords(String(last))
	return spaced.isEmpty ? nil : spaced
}

/// The title Peekaboo shows: the item's own unless it's a placeholder, then its identifier, then its owner and index.
private func resolvedTitle(_ extra: Extra, index: Int) -> String {
	guard isPlaceholder(extra.title) || (isPlaceholder(extra.label) && extra.title == extra.ownerName) else { return extra.title }
	if let name = readableIdentifier(extra.identifier ?? extra.label), !name.isEmpty {
		let ownerMatches = extra.ownerName.flatMap { owner in
			normalizedTitle(name).map { $0.replacingOccurrences(of: " ", with: "") == normalizedTitle(owner)?.replacingOccurrences(of: " ", with: "") }
		} ?? false
		if !ownerMatches { return name }
	}
	if let owner = extra.ownerName, !owner.isEmpty { return "\(owner) #\(index)" }
	if let raw = extra.label, !raw.isEmpty { return "\(raw) #\(index)" }
	return "Menu Bar Item #\(index)"
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? { AX.string(element, attribute) }

/// One process's items from its AXExtrasMenuBar, through groups but not into menus.
private func extrasItems(_ pid: pid_t) -> [(element: AXUIElement, title: String?, description: String?, identifier: String?, frame: CGRect, actions: [String])] {
	let application = AXUIElementCreateApplication(pid)
	AXUIElementSetMessagingTimeout(application, 0.25)
	guard let bar = AX.element(AX.value(application, "AXExtrasMenuBar")) else { return [] }
	var items: [(AXUIElement, String?, String?, String?, CGRect, [String])] = []
	func collect(_ element: AXUIElement, depth: Int) {
		guard depth < 4, items.count < 64 else { return }
		for child in AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
			AXUIElementSetMessagingTimeout(child, 0.25)
			switch axString(child, kAXRoleAttribute) {
			case "AXMenuBarItem":
				guard let frame = AX.frame(child), frame.width > 0, frame.height > 0 else { continue }
				items.append((child, axString(child, kAXTitleAttribute), axString(child, kAXDescriptionAttribute),
				              axString(child, kAXIdentifierAttribute), frame, Mac.actions(child)))
			case "AXGroup": collect(child, depth: depth + 1)
			default: continue
			}
		}
	}
	collect(bar, depth: 0)
	return items
}

// MARK: WindowServer inventory

/// The private CGS calls Peekaboo mirrors from Ice; a missing symbol means no data, not a failure.
private enum CGS {
	typealias Connection = Int32
	nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
		?? dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)

	static func symbol<T>(_ name: String, as _: T.Type) -> T? {
		guard let handle, let found = dlsym(handle, name) else { return nil }
		return unsafeBitCast(found, to: T.self)
	}

	static let main = symbol("CGSMainConnectionID", as: (@convention(c) () -> Connection).self)
	static let activeSpace = symbol("CGSGetActiveSpace", as: (@convention(c) (Connection) -> UInt32).self)
	static let spacesForWindows = symbol("CGSCopySpacesForWindows", as: (@convention(c) (Connection, UInt32, CFArray) -> Unmanaged<CFArray>?).self)

	/// Whether the window is on the active Space; unknown counts as yes, as Peekaboo's does.
	static func onActiveSpace(_ id: CGWindowID) -> Bool {
		guard let main, let activeSpace, let spacesForWindows else { return true }
		let connection = main()
		guard let spaces = spacesForWindows(connection, 1, [id] as CFArray)?.takeRetainedValue() as? [UInt32] else { return true }
		return spaces.contains(activeSpace(connection))
	}

	/// A count-then-list read, refused unless both calls succeed and the list fits the count.
	static func list(count: (UnsafeMutablePointer<Int32>) -> Int32, list: (Int32, UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32) -> [CGWindowID]? {
		var capacity: Int32 = 0
		guard count(&capacity) == 0, capacity >= 0 else { return nil }
		guard capacity > 0 else { return [] }
		var ids = [CGWindowID](repeating: 0, count: Int(capacity))
		var actual: Int32 = 0
		guard list(capacity, &ids, &actual) == 0, (0...capacity).contains(actual) else { return nil }
		return Array(ids.prefix(Int(actual)))
	}

	/// Status item windows on screen on the active Space (CGSCopyWindowsWithOptions, menu bar items).
	static func menuBarItemWindows() -> [CGWindowID] {
		guard let main = symbol("CGSMainConnectionID", as: (@convention(c) () -> UInt32).self),
		      let copy = symbol("CGSCopyWindowsWithOptions", as: (@convention(c) (UInt32, Int32, UInt32) -> CFArray?).self),
		      let raw = copy(main(), 0, 1 << 0 | 1 << 1 | 1 << 2) as? [UInt32]
		else { return [] }
		return raw.map { CGWindowID($0) }.filter(onActiveSpace)
	}

	/// Every process's menu bar windows that are on screen, on the active Space.
	static func processMenuBarWindows() -> [CGWindowID] {
		typealias Count = @convention(c) (Connection, Connection, UnsafeMutablePointer<Int32>) -> Int32
		typealias List = @convention(c) (Connection, Connection, Int32, UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32
		guard let main, let count = symbol("CGSGetWindowCount", as: Count.self), let menuBar = symbol("CGSGetProcessMenuBarWindowList", as: List.self),
		      let onScreenCount = symbol("CGSGetOnScreenWindowCount", as: Count.self), let onScreen = symbol("CGSGetOnScreenWindowList", as: List.self),
		      activeSpace != nil, spacesForWindows != nil
		else { return [] }
		let connection = main()
		guard var ids = list(count: { count(connection, 0, $0) }, list: { menuBar(connection, 0, $0, $1, $2) }) else { return [] }
		if let visible = list(count: { onScreenCount(connection, 0, $0) }, list: { onScreen(connection, 0, $0, $1, $2) }) {
			let visible = Set(visible)
			ids = ids.filter(visible.contains)
		}
		return ids.filter(onActiveSpace)
	}
}

/// What Peekaboo names a WindowServer item: the system owners' placeholders get their product's name, a placeholder
/// takes its identifier's words or its owner's name, and Control Center's camel-cased names are spaced.
func windowItemName(rawTitle: String?, ownerName: String?, bundleID: String?) -> String {
	var resolved = rawTitle?.isEmpty == false ? rawTitle! : (ownerName ?? "Unknown")
	let named = [
		"com.apple.controlcenter": "Control Center", "com.apple.Spotlight": "Spotlight", "com.apple.Siri": "Siri",
		"com.apple.Passwords.MenuBarExtra": "Passwords",
	]
	if let name = bundleID.flatMap({ named[$0] }), isPlaceholder(resolved) { resolved = name }
	if bundleID == "com.apple.systemuiserver", resolved.lowercased() == "menu extras" { resolved = "System Menu Extras" }
	if isPlaceholder(resolved), let name = readableIdentifier(rawTitle) { return name }
	if isPlaceholder(resolved), let ownerName, !ownerName.isEmpty { return ownerName }
	if bundleID == "com.apple.controlcenter", resolved.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, resolved.count > 4,
	   resolved.range(of: #"[A-Z].*[a-z]|[a-z].*[A-Z]"#, options: .regularExpression) != nil
	{
		let spaced = camelCaseToWords(resolved)
		if !spaced.isEmpty, !isPlaceholder(spaced) { return spaced }
	}
	return resolved
}

/// One window's item, or nil unless it is on the main menu (24) or status (25) layer and isn't the bar itself.
func windowItem(_ info: [String: Any], id: CGWindowID, source: String, displays: [CGRect]) -> Extra? {
	let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
	guard layer == 24 || layer == 25, let raw = info[kCGWindowBounds as String] as? NSDictionary,
	      let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
	      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
	else { return nil }
	let owner = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
	let title = info[kCGWindowName as String] as? String ?? ""
	if owner == "Window Server", title == "Menubar" { return nil }
	let app = NSRunningApplication(processIdentifier: pid)
	let bundleID = app?.bundleIdentifier
	// An untitled window takes its app's name; Finder's untitled windows on these layers aren't items.
	let ownerName = title.isEmpty ? app?.localizedName ?? owner : owner
	if app?.localizedName == nil, bundleID == "com.apple.finder", title.isEmpty { return nil }
	let rawTitle = title.isEmpty ? ownerName : title
	let center = CGPoint(x: frame.midX, y: frame.midY)
	return Extra(pid: pid, label: rawTitle, identifier: bundleID ?? (title.isEmpty ? nil : title),
	             title: windowItemName(rawTitle: rawTitle, ownerName: ownerName, bundleID: bundleID), ownerName: ownerName, bundleID: bundleID,
	             frame: frame, isVisible: frame.width > 0 && frame.height > 0 && displays.contains { $0.contains(center) }, actions: [], element: nil,
	             windowID: Int(id), windowLayer: layer, source: source)
}

/// The status item windows WindowServer lists, as Peekaboo's default inventory finds them: the CGS menu bar lists
/// first, then any other window on the status layers.
func windowExtras() -> [Extra] {
	let displays = activeDisplays().map(\.bounds)
	var items: [Extra] = []
	var seen = Set<CGWindowID>()
	// Sorted, so the same windows always come in the same order.
	for id in Set(CGS.menuBarItemWindows() + CGS.processMenuBarWindows()).sorted() {
		guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
		      let item = windowItem(info, id: id, source: "cgs", displays: displays)
		else { continue }
		items.append(item)
		seen.insert(id)
	}
	for info in CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
		guard let id = (info[kCGWindowNumber as String] as? NSNumber).map({ CGWindowID($0.uint32Value) }), !seen.contains(id),
		      let item = windowItem(info, id: id, source: "cgwindow", displays: displays)
		else { continue }
		items.append(item)
		seen.insert(id)
	}
	return windowItemsInOrder(items)
}

/// Top to bottom, then left to right, by each item's center, with ties broken so the order is always the same.
func windowItemsInOrder(_ items: [Extra]) -> [Extra] {
	items.sorted { lhs, rhs in
		let (l, r) = (CGPoint(x: lhs.frame.midX, y: lhs.frame.midY), CGPoint(x: rhs.frame.midX, y: rhs.frame.midY))
		if l.y != r.y { return l.y < r.y }
		if l.x != r.x { return l.x < r.x }
		if lhs.windowID != rhs.windowID { return (lhs.windowID ?? .max) < (rhs.windowID ?? .max) }
		if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
		return (lhs.identifier ?? lhs.title) < (rhs.identifier ?? rhs.title)
	}
}

private final class Results: @unchecked Sendable {
	let lock = NSLock()
	var values: [[Extra]]
	init(_ count: Int) { values = Array(repeating: [], count: count) }
}

/// Every running app's status items, left to right.
@MainActor
private func extras() throws -> [Extra] {
	let running = NSWorkspace.shared.runningApplications
	guard running.contains(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) else { return windowExtras() }
	let owners = running.filter { $0.processIdentifier > 0 && !$0.isTerminated }
	let info = owners.map { ($0.processIdentifier, $0.localizedName, $0.bundleIdentifier) }
	let displays = activeDisplays().map(\.bounds)
	let results = Results(info.count)
	// One unresponsive app costs one timeout, not one each.
	DispatchQueue.concurrentPerform(iterations: info.count) { index in
		let (pid, name, bundle) = info[index]
		let items = extrasItems(pid).map { item -> Extra in
			let label = sanitized(item.title) ?? sanitized(item.description)
			let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
			return Extra(pid: pid, label: label, identifier: sanitized(item.identifier),
			             title: label ?? sanitized(item.identifier) ?? name ?? "Menu Bar Item", ownerName: name, bundleID: bundle,
			             frame: item.frame, isVisible: displays.contains { $0.contains(center) }, actions: item.actions, element: item.element)
		}
		results.lock.withLock { results.values[index] = items }
	}
	// Items sit on one row whose origins differ by fractions of a point; order them left to right.
	return results.values.flatMap { $0 }.sorted { lhs, rhs in
		if lhs.frame.origin.x != rhs.frame.origin.x { return lhs.frame.origin.x < rhs.frame.origin.x }
		if lhs.frame.origin.y != rhs.frame.origin.y { return lhs.frame.origin.y < rhs.frame.origin.y }
		if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
		return (lhs.identifier ?? lhs.title) < (rhs.identifier ?? rhs.title)
	}
}

private func rows(_ extras: [Extra]) -> [StatusItemRow] {
	let titles = extras.enumerated().map { resolvedTitle($1, index: $0) }
	// The set's identity: any item added, removed, moved or renamed changes it.
	let set = extras.enumerated().map { index, extra -> String in
		let anchored = extra.identifier != nil || extra.windowID != nil
		return [String(index), titles[index], String(extra.pid), extra.windowID.map(String.init) ?? "", extra.windowLayer.map(String.init) ?? "",
		        anchored ? "" : extra.title, anchored ? "" : extra.label ?? "", extra.bundleID ?? "", extra.ownerName ?? "", extra.identifier ?? "",
		        extra.source, "\(extra.frame.origin.x),\(extra.frame.origin.y)", String(extra.isVisible)].joined(separator: "\u{1f}")
	}.joined(separator: "\u{1e}")
	return extras.enumerated().map { index, extra in
		let generation = startIdentity(extra.pid).value
		// A window item binds its window only while that window still belongs to the owner, as Peekaboo's evidence does.
		let window = extra.windowID.flatMap { id in Mac.window(id).flatMap { $0.pid == extra.pid ? (id, $0.bounds) : nil } }
		let frame = window?.1 ?? extra.frame
		let leaf = [String(extra.pid), generation.map(String.init) ?? "", window.map { String($0.0) } ?? "", String(index),
		            extra.identifier == nil ? titles[index] : "", extra.identifier ?? "", "\(frame)", set].joined(separator: "\u{1d}")
		return StatusItemRow(index: index, title: titles[index], rawTitle: extra.label, identifier: extra.identifier, ownerName: extra.ownerName,
		                     bundleID: extra.bundleID, pid: extra.pid, generation: generation, frame: frame, isVisible: extra.isVisible,
		                     windowID: window?.0, source: extra.source, leaf: leaf)
	}
}

/// A window on screen, as the menu bar click compares before and after.
public struct OnScreenWindow: Sendable {
	public let pid: pid_t
	public let id: Int
	public let appName: String?
	public let bounds: CGRect
	public let layer: Int
	public var generation: UInt64? { startIdentity(pid).value }
}

private func refusal(_ message: String, hint: String?, reason: String = "target_unavailable") -> Refusal {
	var refusal = Refusal("DESKTOP_ACTION_FAILED", message, hint: hint)
	refusal.reason = reason
	return refusal
}

/// Peekaboo's plain error, which the bridge reports with this code and the client treats as possibly dispatched.
public struct StatusItemFailed: Error {
	public let code: String
	public let message: String
}

/// The press went out but its effect is unknown.
public struct StatusItemUnconfirmed: Error {
	public let delivery: Delivery
	public let message: String
}

extension Mac {
	public static func statusItems() async throws -> [StatusItemRow] {
		try await MainActor.run { try rows(extras()) }
	}

	/// Windows on screen of other processes, front to back.
	public static func onScreenWindows() -> [OnScreenWindow] {
		let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
		let own = getpid()
		return list.compactMap { info in
			guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0, pid != own,
			      let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue, id > 0,
			      let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
			      (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
			      let raw = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
			      bounds.width >= 8, bounds.height >= 8
			else { return nil }
			return OnScreenWindow(pid: pid, id: id, appName: info[kCGWindowOwnerName as String] as? String, bounds: bounds, layer: layer)
		}
	}

	/// Presses the status item at `index` once its identity matches `expected` on two fresh reads: AXPress, or
	/// AXShowMenu where press is absent. Throws Refusal before the press and StatusItemUnconfirmed after it.
	public static func pressStatusItem(index: Int, expected: String) async throws -> Delivery {
		let first = try await statusItems()
		guard first.indices.contains(index) else {
			throw StatusItemFailed(code: "invalidRequest", message: "Invalid menu bar item index: \(index). Valid range: 0-\(first.count - 1)")
		}
		guard first[index].leaf == expected else {
			throw refusal("Menu bar item [\(index)] changed identity or order before dispatch.", hint: "Refresh menu bar items before retrying.")
		}
		guard first[index].isVisible else {
			throw StatusItemFailed(code: "internalError",
			                       message: "Menu bar item '\(first[index].title)' is outside the active displays. It may be hidden by a menu bar manager.")
		}
		let refreshed = try await statusItems()
		guard refreshed.indices.contains(index) else {
			throw refusal("Menu bar item [\(index)] disappeared before dispatch.", hint: "Refresh menu bar items before retrying.")
		}
		guard refreshed[index].leaf == expected else {
			throw refusal("Menu bar item [\(index)] changed identity or order before dispatch.", hint: "Refresh menu bar items before retrying.")
		}
		let item = refreshed[index]
		if item.source != "ax-extras" { return try clickWindowItem(item, index: index) }
		let matches = extrasItems(item.pid).filter { $0.frame == item.frame && sanitized($0.identifier) == item.identifier }
		guard matches.count == 1, startIdentity(item.pid).value == item.generation else {
			throw refusal("Menu bar item [\(index)] no longer resolves to exactly one Accessibility element of its owner.",
			              hint: "Refresh menu bar items before retrying.")
		}
		let action: String
		if matches[0].actions.contains(kAXPressAction) {
			action = kAXPressAction
		} else if matches[0].actions.contains(kAXShowMenuAction) {
			action = kAXShowMenuAction
		} else {
			throw refusal("Menu bar item [\(index)] exposes neither AXPress nor AXShowMenu.",
			              hint: "Choose a menu bar item that exposes a supported Accessibility action.", reason: "operation_unsupported")
		}
		var delivery = Delivery.accepted("accessibility_action")
		delivery.mode = "foreground"
		let element = matches[0].element
		let before = Set(menuSurfaces().map(\.id))
		// An NSMenu-backed item answers AXPress only after its menu closes, so wait briefly.
		AXUIElementSetMessagingTimeout(element, 0.5)
		let error = await perform(element, action)
		if error != .success {
			let opened = error == .cannotComplete ? await menuSurfaceAppeared(since: before, below: item.frame) : false
			guard opened else {
				var unknown = Delivery(state: .indeterminate, mechanism: "accessibility_action", evidence: "completion_unknown", units: 1)
				unknown.mode = "foreground"
				throw StatusItemUnconfirmed(delivery: unknown,
				                            message: "Menu bar item [\(index)] returned AXError \(error.rawValue) without reliable \(action) dispatch evidence.")
			}
		}
		return delivery
	}

	/// Clicks a WindowServer item at its window's center, routed to that window, after checking it is still the
	/// owner's on a routable layer, on screen and visible. Peekaboo's shared-pointer fallback stays off.
	private static func clickWindowItem(_ item: StatusItemRow, index: Int) throws -> Delivery {
		let stale = refusal("Menu bar item has no stable PID/window generation route.", hint: "Refresh menu bar items before retrying.")
		guard let windowID = item.windowID, let generation = item.generation, startIdentity(item.pid).value == generation else { throw stale }
		let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]] ?? []
		guard let info = list.first, (info[kCGWindowNumber as String] as? NSNumber)?.intValue == windowID,
		      (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == item.pid,
		      let raw = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
		      bounds == item.frame
		else { throw stale }
		let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
		let routable = [CGWindowLevelKey.normalWindow, .mainMenuWindow, .statusWindow].map { Int(CGWindowLevelForKey($0)) }
		guard routable.contains(layer), info[kCGWindowIsOnscreen as String] as? Bool == true,
		      (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0
		else {
			throw refusal("Menu bar item cannot use the proven background window-routing transport.",
			              hint: "Use the named Accessibility action path; shared-pointer fallback is disabled.", reason: "operation_unsupported")
		}
		let point = CGPoint(x: bounds.midX, y: bounds.midY)
		guard activeDisplays().contains(where: { $0.bounds.contains(point) }) else {
			throw refusal("Menu bar item '\(item.title)' is outside the active displays. It may be hidden by a menu bar manager.",
			              hint: "Refresh menu bar items before retrying.")
		}
		var delivery = try routedClick(at: point, kind: .single, window: ClickWindow(pid: item.pid, generation: generation, windowID: windowID, bounds: bounds))
		delivery.mode = "background"
		guard delivery.state != .indeterminate else {
			throw StatusItemUnconfirmed(delivery: delivery, message: "Menu bar item [\(index)]'s routed click was interrupted.")
		}
		return delivery
	}

	/// Performs the action on its own thread, so a slow app never holds a cooperative pool thread.
	private static func perform(_ element: AXUIElement, _ action: String) async -> AXError {
		let box = UncheckedBox(element)
		return await withCheckedContinuation { continuation in
			Thread.detachNewThread { continuation.resume(returning: AXUIElementPerformAction(box.value, action as CFString)) }
		}
	}

	private static func menuSurfaces() -> [(id: Int, bounds: CGRect)] {
		let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
		return list.compactMap { info in
			guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
			      let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer > 0,
			      let raw = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
			else { return nil }
			return (id, bounds)
		}
	}

	private static func menuSurfaceAppeared(since before: Set<Int>, below item: CGRect) async -> Bool {
		for _ in 0 ..< 5 {
			let appeared = menuSurfaces().contains { surface in
				!before.contains(surface.id) && surface.bounds.minY <= item.maxY + 64
					&& surface.bounds.maxX >= item.minX - 1024 && surface.bounds.minX <= item.maxX + 1024
			}
			if appeared { return true }
			try? await Task.sleep(for: .milliseconds(100))
		}
		return false
	}

	/// One area of the desktop at one pixel per point, from the display that holds most of it.
	public static func captureArea(_ area: CGRect) async throws -> CGImage {
		guard CGPreflightScreenCaptureAccess() else {
			throw ToolError("permissionDenied: Screen Recording access is off for the Desktop Tools host.")
		}
		let displays = activeDisplays()
		guard let index = displayIndex(area), let display = displays.first(where: { $0.index == index }) else {
			throw ToolError("The opened area is on no display.")
		}
		let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
		guard let screen = content.displays.first(where: { $0.displayID == display.id }) else {
			throw ToolError("The display is not available to ScreenCaptureKit.")
		}
		let local = area.intersection(display.bounds).offsetBy(dx: -display.bounds.minX, dy: -display.bounds.minY)
		let config = SCStreamConfiguration()
		config.sourceRect = local
		config.width = Int(local.width.rounded())
		config.height = Int(local.height.rounded())
		config.showsCursor = false
		return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: screen, excludingWindows: []), configuration: config)
	}
}
