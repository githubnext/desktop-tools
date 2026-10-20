import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation
import ScreenCaptureKit

// Status items, ported from Peekaboo's MenuService+ExtrasMenuBar, its menu bar titles (UIAXHelpers,
// MenuExtraSupport) and its by-index click (MIT). Only the AXExtrasMenuBar inventory is ported: it is the one
// macOS uses where MenuBarAgent draws the whole bar. Older systems' WindowServer inventory is not.

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
	/// What a click compares, as Peekaboo's selected-leaf evidence does: the item's identity and the whole set's.
	public let leaf: String
}

private struct Extra {
	let pid: pid_t
	let label: String?
	let identifier: String?
	let title: String
	let ownerName: String?
	let bundleID: String?
	let frame: CGRect
	let isVisible: Bool
	let actions: [String]
	let element: AXUIElement
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

private final class Results: @unchecked Sendable {
	let lock = NSLock()
	var values: [[Extra]]
	init(_ count: Int) { values = Array(repeating: [], count: count) }
}

/// Every running app's status items, left to right.
@MainActor
private func extras() throws -> [Extra] {
	let running = NSWorkspace.shared.runningApplications
	guard running.contains(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) else {
		throw ToolError("The Swift spike lists status items only where MenuBarAgent draws the menu bar; this system's WindowServer inventory isn't ported.")
	}
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
		let anchored = extra.identifier != nil
		return [String(index), titles[index], String(extra.pid), anchored ? "" : extra.title, anchored ? "" : extra.label ?? "",
		        extra.bundleID ?? "", extra.ownerName ?? "", extra.identifier ?? "", "ax-extras",
		        "\(extra.frame.origin.x),\(extra.frame.origin.y)", String(extra.isVisible)].joined(separator: "\u{1f}")
	}.joined(separator: "\u{1e}")
	return extras.enumerated().map { index, extra in
		let generation = startIdentity(extra.pid).value
		let leaf = [String(extra.pid), generation.map(String.init) ?? "", String(index), extra.identifier == nil ? titles[index] : "",
		            extra.identifier ?? "", "\(extra.frame)", set].joined(separator: "\u{1d}")
		return StatusItemRow(index: index, title: titles[index], rawTitle: extra.label, identifier: extra.identifier, ownerName: extra.ownerName,
		                     bundleID: extra.bundleID, pid: extra.pid, generation: generation, frame: extra.frame, isVisible: extra.isVisible, leaf: leaf)
	}
}

/// A window on screen, as the menu bar click compares before and after.
public struct ScreenWindow: Sendable {
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
	public static func onScreenWindows() -> [ScreenWindow] {
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
			return ScreenWindow(pid: pid, id: id, appName: info[kCGWindowOwnerName as String] as? String, bounds: bounds, layer: layer)
		}
	}

	/// Presses the status item at `index` once its identity matches `expected` on two fresh reads: AXPress, or
	/// AXShowMenu where press is absent. Throws Refusal before the press and StatusItemUnconfirmed after it.
	public static func pressStatusItem(index: Int, expected: String) async throws -> Delivery {
		for _ in 0 ..< 2 {
			let current = try await statusItems()
			guard current.indices.contains(index) else {
				throw refusal("Menu bar item [\(index)] disappeared before dispatch.", hint: "Refresh menu bar items before retrying.")
			}
			guard current[index].leaf == expected else {
				throw refusal("Menu bar item [\(index)] changed identity or order before dispatch.", hint: "Refresh menu bar items before retrying.")
			}
			guard current[index].isVisible else {
				throw refusal("Menu bar item '\(current[index].title)' is outside the active displays. It may be hidden by a menu bar manager.",
				              hint: "Refresh menu bar items before retrying.")
			}
		}
		let item = try await statusItems()[index]
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
