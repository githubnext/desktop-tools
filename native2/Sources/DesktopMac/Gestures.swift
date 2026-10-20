import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// Background scroll and drag, and foreground hover, ported from Peekaboo's ActionInputDriver,
// WindowRoutedPointerDriver and ExactWindowDrag (MIT).

public enum ScrollDirection: String, Sendable {
	case up, down, left, right
	var vertical: Bool { self == .up || self == .down }
	/// Toward the end of the content: a larger scroll bar value.
	var forward: Bool { self == .down || self == .right }
}

/// Mouse events posted to one window's process with that window named as under the pointer, re-checking the
/// window before each event.
struct Router {
	let window: ClickWindow
	let usesSkyLight: Bool
	let setWindowLocation: @convention(c) (CGEvent, CGPoint) -> Void
	let source = CGEventSource(stateID: .hidSystemState)
	private(set) var posted = 0

	init(_ window: ClickWindow) throws {
		guard let setWindowLocation = skyLight.setWindowLocation else {
			throw Refusal("UNSUPPORTED", "This macOS lacks the event routing background pointer input needs.")
		}
		self.window = window
		self.setWindowLocation = setWindowLocation
		usesSkyLight = Mac.routesThroughSkyLight(window.pid)
		if usesSkyLight, skyLight.postToPid == nil {
			throw Refusal("UNSUPPORTED", "This macOS lacks the event routing background pointer input in this app needs.")
		}
	}

	/// Posts one event at a global point. Throws Refusal before the first event and Interrupted after it.
	mutating func post(_ event: CGEvent, at point: CGPoint, group: Int64) throws {
		do { try window.check() } catch {
			if posted > 0 { throw Interrupted() }
			throw error
		}
		event.location = point
		event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(window.pid))
		for field in [51, 91, 92] {
			event.setIntegerValueField(CGEventField(rawValue: UInt32(field))!, value: Int64(window.windowID))
		}
		event.setIntegerValueField(CGEventField(rawValue: 58)!, value: group)
		setWindowLocation(event, CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY))
		if usesSkyLight { skyLight.postToPid!(window.pid, event) } else { event.postToPid(window.pid) }
		posted += 1
	}

	/// A mouse event with Peekaboo's click fields.
	func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64) -> CGEvent? {
		guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return nil }
		event.flags = []
		event.setIntegerValueField(.mouseEventClickState, value: clickState)
		event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
		event.setIntegerValueField(.mouseEventSubtype, value: 3)
		return event
	}

	static func newGroup() -> Int64 { Int64(bitPattern: DispatchTime.now().uptimeNanoseconds) }

	struct Interrupted: Error {}
}

extension Mac {
	// MARK: Scroll

	/// Scrolls an observed element: its scroll bar's value, page actions, scroll bar steps, then a wheel for
	/// WebKit views. Anything else is refused rather than guessed at.
	public static func scroll(_ element: AXUIElement, direction: ScrollDirection, amount: Int, window: ClickWindow) throws -> Delivery {
		AXUIElementSetMessagingTimeout(element, 1)
		if let delivery = try scrollThroughAccessibility(element, direction: direction, amount: amount, ownBarsOnly: false, window: window) {
			return delivery
		}
		let role = AX.string(element, kAXRoleAttribute) ?? ""
		if ["AXGroup", "AXWebArea", "AXScrollArea"].contains(role), let frame = AX.frame(element), wheelReaches(window.pid) {
			return try wheel(at: CGPoint(x: frame.midX, y: frame.midY), direction: direction, amount: amount, window: window)
		}
		throw noScrollRoute
	}

	/// Scrolls whatever scrolls at a point: the nearest scroll container there, else a wheel for WebKit views.
	public static func scroll(at point: CGPoint, direction: ScrollDirection, amount: Int, window: ClickWindow) throws -> Delivery {
		let app = AXUIElementCreateApplication(window.pid)
		AXUIElementSetMessagingTimeout(app, 1)
		var hit: AXUIElement?
		if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var current = hit {
			for _ in 0..<32 {
				let role = AX.string(current, kAXRoleAttribute) ?? ""
				if role == "AXWindow" { break }
				if let owner = AX.element(AX.value(current, kAXWindowAttribute)), AX.windowID(owner) != window.windowID {
					throw Refusal("TARGET_OCCLUDED", "Another window of this app covers that point. Inspect the window on top instead.")
				}
				let names = actions(current)
				if ["AXScrollArea", "AXScrollBar", "AXWebArea"].contains(role) || names.contains(where: { $0.hasPrefix("AXScroll") && $0.hasSuffix("ByPage") }) {
					if let delivery = try scrollThroughAccessibility(current, direction: direction, amount: amount, ownBarsOnly: true, window: window) {
						return delivery
					}
					if ["AXGroup", "AXWebArea", "AXScrollArea"].contains(role), wheelReaches(window.pid) {
						return try wheel(at: point, direction: direction, amount: amount, window: window)
					}
					throw noScrollRoute
				}
				guard let parent = AX.element(AX.value(current, kAXParentAttribute)) else { break }
				current = parent
			}
		}
		guard wheelReaches(window.pid) else { throw noScrollRoute }
		return try wheel(at: point, direction: direction, amount: amount, window: window)
	}

	private static let noScrollRoute = {
		var refusal = Refusal(
			"DESKTOP_ACTION_FAILED", "Background scroll has no supported route for the observed target.",
			hint: "Observe again and select a scrollable control or eligible WebKit content element.",
			cause: "Accessibility action is not supported"
		)
		refusal.reason = "operation_unsupported"
		return refusal
	}()

	private static func scrollThroughAccessibility(_ element: AXUIElement, direction: ScrollDirection, amount: Int, ownBarsOnly: Bool, window: ClickWindow) throws -> Delivery? {
		let bar = scrollBar(of: element, vertical: direction.vertical, ownBarsOnly: ownBarsOnly)
		// The bar's value, read back.
		if let bar, settable(bar, kAXValueAttribute), let current = (AX.value(bar, kAXValueAttribute) as? NSNumber)?.doubleValue {
			let low = (AX.value(bar, kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
			let high = (AX.value(bar, kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 1
			let step = (AX.value(bar, "AXValueIncrement") as? NSNumber)?.doubleValue ?? (high - low) / 10
			let next = min(high, max(low, current + (direction.forward ? 1 : -1) * step * Double(amount)))
			try window.check()
			let error = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: next))
			if error == .success {
				Thread.sleep(forTimeInterval: 0.02)
				let after = (AX.value(bar, kAXValueAttribute) as? NSNumber)?.doubleValue
				if let after, after != current {
					return Delivery(state: .confirmedChange, mechanism: "accessibility_value", evidence: "verified_change", units: 1)
				}
				return Delivery(state: .indeterminate, mechanism: "accessibility_value", evidence: "completion_unknown", units: 1)
			}
		}
		// Page actions on the element itself.
		let name = direction.rawValue.capitalized
		let names = actions(element)
		if let page = ["AXScroll\(name)ByPage", "AXPage\(name)"].first(where: names.contains) {
			return try repeatAction(page, on: element, times: amount, window: window)
		}
		// Steps on the scroll bar.
		if let bar {
			let step = direction.forward ? kAXIncrementAction : kAXDecrementAction
			if actions(bar).contains(step) { return try repeatAction(step, on: bar, times: amount, window: window) }
		}
		return nil
	}

	private static func repeatAction(_ action: String, on element: AXUIElement, times: Int, window: ClickWindow) throws -> Delivery {
		var done = 0
		for _ in 0..<times {
			do { try window.check() } catch {
				if done == 0 { throw error }
				return Delivery(state: .indeterminate, mechanism: "accessibility_action", evidence: "completion_unknown", units: done)
			}
			let error = AXUIElementPerformAction(element, action as CFString)
			guard error == .success else {
				if done == 0, error == .actionUnsupported { throw noScrollRoute }
				return Delivery(state: .indeterminate, mechanism: "accessibility_action", evidence: "completion_unknown", units: done)
			}
			done += 1
		}
		return .accepted("accessibility_action", units: done)
	}

	/// The element's scroll bar for one orientation, breadth first, never inside a nested scroll area.
	private static func scrollBar(of element: AXUIElement, vertical: Bool, ownBarsOnly: Bool) -> AXUIElement? {
		func matches(_ bar: AXUIElement) -> Bool {
			if let orientation = AX.string(bar, kAXOrientationAttribute) {
				return orientation == (vertical ? kAXVerticalOrientationValue : kAXHorizontalOrientationValue) as String
			}
			guard let frame = AX.frame(bar) else { return false }
			return vertical ? frame.height > frame.width : frame.width > frame.height
		}
		if AX.string(element, kAXRoleAttribute) == "AXScrollBar" { return matches(element) ? element : nil }
		for attribute in [vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute] {
			if let bar = AX.element(AX.value(element, attribute)), matches(bar) { return bar }
		}
		var queue = AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
		var seen = 0
		while !queue.isEmpty, seen < 200 {
			let next = queue.removeFirst()
			seen += 1
			let role = AX.string(next, kAXRoleAttribute)
			if role == "AXScrollBar", matches(next) { return next }
			if ownBarsOnly || role == "AXScrollArea" { continue }
			queue += AX.value(next, kAXChildrenAttribute) as? [AXUIElement] ?? []
		}
		return nil
	}

	/// Line-unit wheel ticks posted to the window, 12 ms apart.
	private static func wheel(at point: CGPoint, direction: ScrollDirection, amount: Int, window: ClickWindow) throws -> Delivery {
		guard window.bounds.contains(point) else { throw Refusal("POINT_OUTSIDE_WINDOW", "The point is outside the exact window.") }
		var router = try Router(window)
		let dy: Int32 = direction == .up ? 1 : direction == .down ? -1 : 0
		let dx: Int32 = direction == .left ? 1 : direction == .right ? -1 : 0
		do {
			for tick in 0..<amount {
				if tick > 0 { Thread.sleep(forTimeInterval: 0.012) }
				guard let event = CGEvent(scrollWheelEvent2Source: router.source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
					throw Router.Interrupted()
				}
				try router.post(event, at: point, group: Router.newGroup())
			}
		} catch is Router.Interrupted {
			return Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: router.posted)
		}
		return .accepted("window_targeted_events", units: router.posted)
	}

	/// Background wheel events reach only AppKit apps hosting WebKit views (or Safari), and not while hidden.
	private static func wheelReaches(_ pid: pid_t) -> Bool {
		guard let app = NSRunningApplication(processIdentifier: pid), !app.isHidden, !routesThroughSkyLight(pid) else { return false }
		if app.bundleIdentifier == "com.apple.Safari" { return true }
		guard let executable = app.executableURL else { return false }
		return linkedLibraries(executable).contains { $0.contains("/WebKit.framework/") }
	}

	// MARK: Drag

	/// Presses at the first point, moves through the rest and releases at the last, all in one window.
	public static func drag(_ points: [CGPoint], button: CGMouseButton, milliseconds: Int, window: ClickWindow) throws -> Delivery {
		guard points.count >= 2, points.allSatisfy(window.bounds.contains) else {
			throw Refusal("POINT_OUTSIDE_WINDOW", "Every drag point must be inside the exact window.")
		}
		let steps = min(96, max(20, (points.count - 1) * 4))
		let samples = polyline(points, steps: steps)
		let (down, dragged, up): (CGEventType, CGEventType, CGEventType) = button == .right
			? (.rightMouseDown, .rightMouseDragged, .rightMouseUp) : (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
		var router = try Router(window)
		let group = Router.newGroup()
		let interval = Double(milliseconds) / 1000 / Double(steps)
		var pressed = false
		do {
			guard let primer = router.mouse(.mouseMoved, at: points[0], button: button, clickState: 0) else { throw Router.Interrupted() }
			try router.post(primer, at: points[0], group: group)
			Thread.sleep(forTimeInterval: 0.012)
			guard let press = router.mouse(down, at: points[0], button: button, clickState: 1) else { throw Router.Interrupted() }
			try router.post(press, at: points[0], group: group)
			pressed = true
			for sample in samples {
				Thread.sleep(forTimeInterval: interval)
				guard let move = router.mouse(dragged, at: sample, button: button, clickState: 1) else { throw Router.Interrupted() }
				try router.post(move, at: sample, group: group)
			}
			guard let release = router.mouse(up, at: points.last!, button: button, clickState: 1) else { throw Router.Interrupted() }
			try router.post(release, at: points.last!, group: group)
		} catch is Router.Interrupted {
			// The button is never left down in the app, even when the window changed mid-drag.
			if pressed, let release = router.mouse(up, at: points.last!, button: button, clickState: 1) {
				release.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(window.pid))
				release.postToPid(window.pid)
			}
			return Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: router.posted)
		}
		return .accepted("window_targeted_events", units: router.posted)
	}

	/// `steps` points after the first along the path, at least one per segment and the rest by length,
	/// landing exactly on each waypoint.
	static func polyline(_ points: [CGPoint], steps: Int) -> [CGPoint] {
		let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
		let total = lengths.reduce(0, +)
		let spare = steps - lengths.count
		let shares = lengths.map { total > 0 ? Double(spare) * $0 / total : Double(spare) / Double(lengths.count) }
		var counts = shares.map { 1 + Int($0) }
		let order = shares.indices.sorted { shares[$0] - shares[$0].rounded(.down) > shares[$1] - shares[$1].rounded(.down) }
		for index in order.prefix(steps - counts.reduce(0, +)) { counts[index] += 1 }
		var samples: [CGPoint] = []
		for (segment, count) in counts.enumerated() {
			let (a, b) = (points[segment], points[segment + 1])
			for step in 1...count {
				let t = CGFloat(step) / CGFloat(count)
				samples.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
			}
		}
		return samples
	}

	// MARK: Hover

	/// Moves the real pointer to a point the target window shows on top, in 15 steps over 250 ms.
	public static func hover(at point: CGPoint, window: ClickWindow) throws -> Delivery {
		try window.check()
		guard exposes(point, window: window) else {
			throw Refusal("TARGET_OCCLUDED", "Another window covers that point, so hovering there would reach it instead. Bring the target window forward with desktop_focus, then inspect again.")
		}
		let start = CGEvent(source: nil)?.location ?? point
		for step in 1...15 {
			let t = CGFloat(step) / 15
			let at = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
			CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
			Thread.sleep(forTimeInterval: 0.25 / 15)
		}
		var delivery = Delivery(state: .dispatchedUnverified, mechanism: "global_events", evidence: "delivery_accepted", units: 1)
		delivery.mode = "foreground"
		if let now = CGEvent(source: nil)?.location, hypot(now.x - point.x, now.y - point.y) <= 1, exposes(point, window: window) {
			delivery.fields = [("pointer_moved", true)]
			return delivery
		}
		delivery.unverified = true
		let moved = (CGEvent(source: nil)?.location).map { hypot($0.x - point.x, $0.y - point.y) <= 1 } ?? false
		delivery.fields = [("pointer_moved", JSON(moved)), ("error", .object([
			("code", "DESKTOP_ACTION_UNVERIFIED"),
			("message", JSON(moved ? "The pointer arrived, but the exact window was no longer frontmost there." : "The pointer could not be confirmed at the requested point.")),
			("hint", "Inspect the target before retrying; the action may already have happened."),
		]))]
		return delivery
	}

	/// Whether the topmost on-screen window at the point is the target, at its observed bounds.
	public static func exposes(_ point: CGPoint, window: ClickWindow) -> Bool {
		// The host's own windows, such as Desktop Tools' highlight around the target, never count as cover.
		let hosts = Set([getpid()] + NSRunningApplication.runningApplications(withBundleIdentifier: "dev.githubnext.desktop-tools").map(\.processIdentifier))
		let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
		for row in rows {
			guard !hosts.contains(row[kCGWindowOwnerPID as String] as? pid_t ?? 0), (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
			      let raw = row[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw),
			      bounds.contains(point)
			else { continue }
			return row[kCGWindowNumber as String] as? Int == window.windowID
				&& abs(bounds.minX - window.bounds.minX) < 1 && abs(bounds.minY - window.bounds.minY) < 1
				&& abs(bounds.width - window.bounds.width) < 1 && abs(bounds.height - window.bounds.height) < 1
		}
		return false
	}
}

/// The dylibs an executable links, from its Mach-O load commands (the arm64 slice of a universal binary).
func linkedLibraries(_ url: URL) -> [String] {
	guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
	defer { try? handle.close() }
	func read(_ offset: UInt64, _ count: Int) -> Data? {
		try? handle.seek(toOffset: offset)
		return try? handle.read(upToCount: count)
	}
	func u32(_ data: Data, _ at: Int, big: Bool = false) -> UInt32 {
		let value = data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
		return big ? UInt32(bigEndian: value) : value
	}
	guard let head = read(0, 4096), head.count >= 32 else { return [] }
	var base: UInt64 = 0
	if u32(head, 0, big: true) == 0xCAFE_BABE {
		let count = Int(u32(head, 4, big: true))
		var chosen: UInt64?
		for index in 0..<min(count, 16) {
			let entry = 8 + index * 20
			guard entry + 20 <= head.count else { break }
			let offset = UInt64(u32(head, entry + 8, big: true))
			if chosen == nil || u32(head, entry, big: true) == 0x0100_000C { chosen = offset }
		}
		guard let chosen else { return [] }
		base = chosen
	}
	guard let header = read(base, 32), header.count == 32, u32(header, 0) == 0xFEED_FACF else { return [] }
	let commands = Int(u32(header, 16))
	let size = Int(u32(header, 20))
	guard size < 4 << 20, let data = read(base + 32, size), data.count == size else { return [] }
	var libraries: [String] = []
	var at = 0
	for _ in 0..<commands where at + 8 <= data.count {
		let command = u32(data, at)
		let length = Int(u32(data, at + 4))
		guard length >= 8, at + length <= data.count else { break }
		if [0xC, 0x8000_0018, 0x8000_001F, 0x8000_0023].contains(command) {
			let name = Int(u32(data, at + 8))
			if name < length {
				let bytes = data.subdata(in: at + name..<at + length).prefix { $0 != 0 }
				libraries.append(String(decoding: bytes, as: UTF8.self))
			}
		}
		at += length
	}
	return libraries
}
