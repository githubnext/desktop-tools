import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// Background scroll for web content that has no Accessibility scroll route and takes no background wheel, such
// as a Chrome page (#201): arrow keys to the window's keyboard focus while that focus is on the page and won't
// move a caret or a selection, as desktop_key pagedown does. Each scroll unit is one arrow key.

/// Focused roles that consume arrow keys themselves, so arrows wouldn't scroll the page.
private let arrowConsumers: Set<String> = [
	"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXSearchField", "AXSlider", "AXIncrementor",
	"AXPopUpButton", "AXMenuButton", "AXList", "AXTable", "AXOutline", "AXGrid", "AXTree", "AXRadioButton",
	"AXRadioGroup", "AXTabGroup", "AXMenu", "AXMenuBar", "AXMenuItem", "AXColorWell", "AXDateField",
]

extension Mac {
	/// The outermost web area an element is in: itself, the one a scroll area holds, or an ancestor.
	static func webArea(of element: AXUIElement) -> AXUIElement? {
		var found: AXUIElement?
		if AX.string(element, kAXRoleAttribute) == "AXScrollArea" {
			found = (AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).first { AX.string($0, kAXRoleAttribute) == "AXWebArea" }
		}
		var current = found ?? element
		for _ in 0..<64 {
			switch AX.string(current, kAXRoleAttribute) {
			case "AXWebArea": found = current
			case "AXWindow", "AXApplication", nil: return found
			default: break
			}
			guard let parent = AX.element(AX.value(current, kAXParentAttribute)) else { return found }
			current = parent
		}
		return found
	}

	/// Arrow keys to the window's keyboard focus, which must be on the page, read back by its content moving.
	static func keyScroll(_ web: AXUIElement, direction: ScrollDirection, amount: Int, window: ClickWindow) throws -> Delivery {
		let target = KeyboardTarget(window: window, focusedRole: nil, focusedFrame: nil)
		let hint = "Click a spot on the page that isn't a field or control with desktop_click, inspect again, then scroll; or send desktop_key pagedown or pageup once the page holds focus."
		let focused: AXUIElement
		do { focused = try requireKeyboardFocus(target) } catch {
			throw Refusal(
				"DESKTOP_ACTION_FAILED",
				"This page scrolls in the background only with arrow keys, which go to the app's keyboard focus, and that focus isn't in this window. Nothing was sent.",
				hint: hint
			)
		}
		var inPage = false
		var current = focused
		for _ in 0..<64 {
			if CFEqual(current, web) { inPage = true; break }
			guard let parent = AX.element(AX.value(current, kAXParentAttribute)) else { break }
			current = parent
		}
		let role = AX.string(focused, kAXRoleAttribute) ?? ""
		let subrole = AX.string(focused, kAXSubroleAttribute) ?? ""
		guard inPage else {
			throw Refusal(
				"DESKTOP_ACTION_FAILED",
				"This page scrolls in the background only with arrow keys, which go to the window's keyboard focus, and that focus is outside the page. Nothing was sent.",
				hint: hint
			)
		}
		if arrowConsumers.contains(role) || arrowConsumers.contains(subrole) || AX.value(focused, "AXEditableAncestor") != nil {
			throw Refusal(
				"DESKTOP_ACTION_FAILED",
				"This page scrolls in the background only with arrow keys, which go to the window's keyboard focus, and the focused \(role.isEmpty ? "element" : role) would take them instead of scrolling. Nothing was sent.",
				hint: hint
			)
		}
		let before = landmarks(web)
		let chord = try chord(direction.rawValue, modifiers: [])
		var sent = 0
		for index in 0..<amount {
			if index > 0 { usleep(30_000) }
			do {
				let delivery = try press(chord, target: target)
				guard delivery.outcome == "completed" else { break }
				sent += 1
			} catch where sent > 0 { break }
		}
		var delivery = scrolled(before, direction: direction)
			? Delivery(state: .confirmedChange, mechanism: "window_targeted_events", evidence: "verified_change", units: sent)
			: sent < amount
			? Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: sent)
			: .accepted("window_targeted_events", units: sent)
		delivery.fields = [("receiver", "window_focus")]
		return delivery
	}

	/// Wraps a wheel on web content with the same read-back as the keys.
	static func readingBack(_ web: AXUIElement?, direction: ScrollDirection, _ send: () throws -> Delivery) throws -> Delivery {
		guard let web else { return try send() }
		let before = landmarks(web)
		let delivery = try send()
		guard delivery.state == .dispatchedUnverified, scrolled(before, direction: direction) else { return delivery }
		return Delivery(state: .confirmedChange, mechanism: delivery.mechanism, evidence: "verified_change", units: delivery.units)
	}

	/// Up to 64 elements in the page with their frames, breadth first, to tell later whether the content moved.
	static func landmarks(_ web: AXUIElement) -> [(AXUIElement, CGRect)] {
		var found: [(AXUIElement, CGRect)] = []
		var queue = AX.value(web, kAXChildrenAttribute) as? [AXUIElement] ?? []
		var seen = 0
		let deadline = ContinuousClock.now + .milliseconds(150)
		while !queue.isEmpty, seen < 400, found.count < 64, ContinuousClock.now < deadline {
			let next = queue.removeFirst()
			seen += 1
			AXUIElementSetMessagingTimeout(next, 0.2)
			if let frame = AX.frame(next), frame.width > 0, frame.height > 0 { found.append((next, frame)) }
			queue += AX.value(next, kAXChildrenAttribute) as? [AXUIElement] ?? []
		}
		return found
	}

	/// Whether any landmark moved the way the content moves for this direction, within half a second.
	static func scrolled(_ before: [(AXUIElement, CGRect)], direction: ScrollDirection) -> Bool {
		guard !before.isEmpty else { return false }
		let deadline = ContinuousClock.now + .milliseconds(500)
		repeat {
			Thread.sleep(forTimeInterval: 0.05)
			for (element, frame) in before {
				guard let now = AX.frame(element) else { continue }
				let moved = switch direction {
				case .down: now.minY < frame.minY - 0.5
				case .up: now.minY > frame.minY + 0.5
				case .right: now.minX < frame.minX - 0.5
				case .left: now.minX > frame.minX + 0.5
				}
				if moved { return true }
			}
		} while ContinuousClock.now < deadline
		return false
	}

	/// Whether an app hosts WebKit views: its executable, or a library shipped beside it that it loads at run time
	/// (as an Electrobun app's launcher does), links WebKit.
	static func hostsWebKit(_ app: NSRunningApplication) -> Bool {
		guard let executable = app.executableURL else { return false }
		if let known = webKitHosts.value[executable.path] { return known }
		var candidates = [executable]
		let folder = executable.deletingLastPathComponent()
		if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
			candidates += names.filter { $0.hasSuffix(".dylib") }.prefix(32).map { folder.appendingPathComponent($0) }
		}
		let hosts = candidates.contains { linkedLibraries($0).contains { $0.contains("/WebKit.framework/") } }
		webKitHosts.value[executable.path] = hosts
		return hosts
	}

	private static let webKitHosts = Locked<[String: Bool]>([:])
}
