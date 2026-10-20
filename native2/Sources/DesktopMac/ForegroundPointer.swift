import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// Foreground pointer input: modifier clicks and drags with the real pointer, ported from Peekaboo's
// ForegroundModifierClickExecutor, UIAutomationService+ModifierClick, SyntheticInputDriver's cursor restoration,
// FocusManagementService and GestureService (MIT). They activate the target app, so each one captures the
// pointer and the focused window first and hands them back only while nothing newer has taken them.

/// The window server's counts of every input event, and which keys and buttons are down. Any change Peekaboo
/// didn't make itself means a person or another agent took the pointer or keyboard, and their state wins.
struct InputActivity: Equatable {
	var moved, leftDragged, rightDragged, otherDragged: UInt32
	var leftDown, leftUp, rightDown, rightUp, otherDown, otherUp: UInt32
	var keyDown, keyUp, flagsChanged, scrollWheel: UInt32
	let heldKeys: [Bool]
	let heldButtons: [Bool]

	var hasHeldInput: Bool { heldKeys.contains(true) || heldButtons.contains(true) }

	static func current() -> InputActivity {
		let state = CGEventSourceStateID.combinedSessionState
		func count(_ type: CGEventType) -> UInt32 { CGEventSource.counterForEventType(state, eventType: type) }
		// Caps Lock's key state is its latch, not a held key.
		let keys = (CGKeyCode(0)..<128).map { $0 != 0x39 && CGEventSource.keyState(state, key: $0) }
		let buttons = (UInt32(0)..<32).map { CGMouseButton(rawValue: $0).map { CGEventSource.buttonState(state, button: $0) } ?? false }
		return InputActivity(
			moved: count(.mouseMoved), leftDragged: count(.leftMouseDragged), rightDragged: count(.rightMouseDragged),
			otherDragged: count(.otherMouseDragged), leftDown: count(.leftMouseDown), leftUp: count(.leftMouseUp),
			rightDown: count(.rightMouseDown), rightUp: count(.rightMouseUp), otherDown: count(.otherMouseDown),
			otherUp: count(.otherMouseUp), keyDown: count(.keyDown), keyUp: count(.keyUp), flagsChanged: count(.flagsChanged),
			scrollWheel: count(.scrollWheel), heldKeys: keys, heldButtons: buttons
		)
	}

	/// The counts after this host's own modifier click.
	func afterClick(_ clicks: Int, modifiers: Int) -> InputActivity {
		var next = self
		next.leftDown &+= UInt32(clicks)
		next.leftUp &+= UInt32(clicks)
		next.flagsChanged &+= UInt32(modifiers * 2)
		return next
	}

	func afterMove() -> InputActivity {
		var next = self
		next.moved &+= 1
		return next
	}
}

/// The frontmost app and its focused window, which a foreground action takes and then gives back.
struct FocusState: Equatable {
	let pid: pid_t
	let generation: UInt64
	let window: WindowKey?
}

/// One exact window: its owner's generation, number and bounds.
struct WindowKey: Equatable {
	let pid: pid_t
	let generation: UInt64
	let windowID: Int
	let bounds: CGRect

	init(_ window: ClickWindow) {
		self.init(pid: window.pid, generation: window.generation, windowID: window.windowID, bounds: window.bounds)
	}

	init(pid: pid_t, generation: UInt64, windowID: Int, bounds: CGRect) {
		self.pid = pid
		self.generation = generation
		self.windowID = windowID
		self.bounds = bounds
	}
}

/// What a foreground action reports about giving the pointer or focus back.
public enum Restoration: String, Sendable {
	case notNeeded = "not_needed"
	case restored
	/// The state no longer matched this host's last write, so newer user or application state won.
	case preservedNewerState = "preserved_newer_state"
}

/// Input already dispatched, which the result reports with its partial evidence.
struct Dispatched: Error {
	let message: String
	var hint = "Observe the exact target before deciding whether to retry."
	var cause: String?
}

/// Counts the units of a multi-step foreground action and the mechanisms they used.
struct Steps {
	private(set) var units = 0
	private var mechanisms: [String] = []

	mutating func record(_ mechanism: String, units count: Int = 1) {
		guard count > 0 else { return }
		units += count
		mechanisms.append(mechanism)
	}

	/// One mechanism, or composite when the steps crossed several.
	var mechanism: String? {
		guard let first = mechanisms.first else { return nil }
		return mechanisms.allSatisfy { $0 == first } ? first : "composite"
	}

	var dispatched: Bool { units > 0 }

	func outcome(_ state: Delivery.State, evidence: String) -> Delivery {
		var delivery = Delivery(state: state, mechanism: mechanism, evidence: evidence, units: units)
		delivery.mode = "foreground"
		return delivery
	}
}

private func onMainThread<T>(_ work: () -> T) -> T {
	Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
}

extension Mac {
	// MARK: Focus

	static func frontmost() -> (pid: pid_t, generation: UInt64)? {
		guard let pid = onMainThread({ NSWorkspace.shared.frontmostApplication?.processIdentifier }),
		      let generation = generation(pid)
		else { return nil }
		return (pid, generation)
	}

	/// The frontmost app's focused window, at its current WindowServer bounds.
	static func focusedWindow() -> WindowKey? {
		guard let (pid, generation) = frontmost() else { return nil }
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, 0.5)
		guard let window = AX.element(AX.value(app, kAXFocusedWindowAttribute)), let id = AX.windowID(window),
		      let row = Mac.window(id), row.pid == pid
		else { return nil }
		return WindowKey(pid: pid, generation: generation, windowID: id, bounds: row.bounds)
	}

	static func focusState() -> FocusState? {
		guard let (pid, generation) = frontmost() else { return nil }
		let window = focusedWindow()
		guard window == nil || window?.pid == pid else { return nil }
		return FocusState(pid: pid, generation: generation, window: window)
	}

	/// The window's AX element, found by its number among its app's windows.
	static func axWindow(_ window: WindowKey) -> AXUIElement? {
		let app = AXUIElementCreateApplication(window.pid)
		AXUIElementSetMessagingTimeout(app, 1)
		let windows = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
		return windows.first { AX.windowID($0) == window.windowID }
	}

	/// Whether the window is still the same window at the same place.
	static func current(_ window: WindowKey) -> Bool {
		generation(window.pid) == window.generation && Mac.window(window.windowID).map { $0.pid == window.pid && $0.bounds == window.bounds } == true
	}

	/// Brings one exact window to the front as FocusManagementService does: activate its app, make it main, raise
	/// it, and read the focus back. `owns` runs before each step, and throws when newer input took over; a step
	/// whose result already shows the target focused stops early.
	static func focus(_ target: WindowKey, steps: inout Steps, owns: () throws -> Void) throws {
		func reached() -> Bool { focusState() == FocusState(pid: target.pid, generation: target.generation, window: target) }
		guard current(target), let app = NSRunningApplication(processIdentifier: target.pid) else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click exact-window receipt is stale.")
		}
		try owns()
		if reached() { return }
		if !onMainThread({ app.isActive }) {
			try owns()
			if activate(app) { steps.record("native_framework") }
			// Activation can take a moment to show in the frontmost app.
			for _ in 0..<30 where frontmost()?.pid != target.pid { Thread.sleep(forTimeInterval: 0.1) }
			guard frontmost()?.pid == target.pid else {
				throw Dispatched(message: "Exact-window focus stopped after a partial foreground dispatch.", cause: "\(app.localizedName ?? "The application") didn't become frontmost.")
			}
			if reached() { return }
		}
		guard let element = axWindow(target) else {
			throw Dispatched(message: "Exact-window focus stopped after a partial foreground dispatch.", cause: "The window's Accessibility element wasn't found.")
		}
		for attempt in 0..<2 {
			if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
			try owns()
			if AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success {
				steps.record("accessibility_value")
				if reached() { return }
			}
			try owns()
			if AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success { steps.record("accessibility_action") }
			let deadline = Date().addingTimeInterval(2)
			while Date() < deadline {
				if reached() { return }
				Thread.sleep(forTimeInterval: 0.1)
			}
		}
		throw Dispatched(message: "Exact-window focus stopped after a partial foreground dispatch.", cause: "Focus verification timed out for window \(target.windowID).")
	}

	/// Activates an app from this background host: cooperative activation first, then Accessibility, which works
	/// when the host isn't frontmost itself.
	static func activate(_ app: NSRunningApplication) -> Bool {
		if onMainThread({ app.activate() }) {
			for _ in 0..<10 where frontmost()?.pid != app.processIdentifier { Thread.sleep(forTimeInterval: 0.02) }
			if frontmost()?.pid == app.processIdentifier { return true }
		}
		let element = AXUIElementCreateApplication(app.processIdentifier)
		AXUIElementSetMessagingTimeout(element, 1)
		return AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
	}

	/// Moves the pointer back to where it was, unless anything else moved it meanwhile.
	static func restoreCursor(_ original: CGPoint, lastWritten: CGPoint, activity: InputActivity) throws -> Restoration {
		func matches(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 0.5 && abs(a.y - b.y) <= 0.5 }
		guard InputActivity.current() == activity else { return .preservedNewerState }
		guard let now = CGEvent(source: nil)?.location else {
			throw Dispatched(message: "Modifier-click could not restore the physical cursor.", cause: "The physical cursor did not return to its captured location.")
		}
		if matches(now, original) { return .notNeeded }
		guard matches(now, lastWritten), InputActivity.current() == activity else { return .preservedNewerState }
		CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?.post(tap: .cghidEventTap)
		// The window server applies the move after the post returns.
		for attempt in 0..<20 {
			if attempt > 0 { Thread.sleep(forTimeInterval: 0.01) }
			if let at = CGEvent(source: nil)?.location, matches(at, original) { return .restored }
		}
		throw Dispatched(message: "The physical cursor restoration was dispatched but could not be verified.", hint: "Inspect the shared desktop state before taking another input action.")
	}

	// MARK: Modifier click

	/// A click holding command, option or shift, which Accessibility presses can't carry: activate the app, click
	/// with the real pointer, then give the pointer and focus back.
	public static func modifierClick(at point: CGPoint, kind: ClickKind, modifiers: [String], window: ClickWindow) throws -> Delivery {
		guard window.bounds.contains(point) else {
			var refusal = Refusal("DESKTOP_ACTION_FAILED", "Modifier-click point must be finite and inside the exact target window.")
			refusal.reason = "invalid_request"
			throw refusal
		}
		let target = WindowKey(window)
		guard current(target) else { throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click exact-window receipt is stale.") }
		let clicks = kind == .double ? 2 : kind == .triple ? 3 : 1
		guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState) else {
			var refusal = Refusal(
				"DESKTOP_ACTION_FAILED", "Modifier-click could not prepare its event sequence before foreground setup.",
				hint: "Grant Event Synthesizing permission or inspect the runtime before retrying."
			)
			refusal.reason = "permission_denied"
			throw refusal
		}
		let events = modifierClickEvents(at: point, clicks: clicks, modifiers: modifiers, source: source)
		guard let prior = frontmost() else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click could not capture the prior foreground application for restoration.")
		}
		guard let priorWindow = focusedWindow() else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click could not capture the exact prior focused window for restoration.")
		}
		guard CGEvent(source: nil)?.location != nil else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click could not capture the physical cursor for restoration.")
		}
		let initial = InputActivity.current()
		guard !initial.hasHeldInput else {
			throw Refusal(
				"DESKTOP_ACTION_FAILED", "Modifier-click requires every autorepeating key or held mouse button to be released before focus.",
				hint: "Release held input and retry from a fresh observation."
			)
		}
		let targetState = FocusState(pid: target.pid, generation: target.generation, window: target)
		var steps = Steps()
		var failure: Error?
		var cleanupAllowed = true
		var activity: InputActivity? = initial
		var original: CGPoint?
		var clicked = false

		// Focus the exact window, unless newer input arrives first.
		do {
			try focus(target, steps: &steps) {
				guard InputActivity.current() == initial else {
					throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click shared input changed before target focus dispatch.")
				}
			}
			guard focusState() == targetState, current(target) else {
				throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click could not confirm the exact foreground window.")
			}
		} catch {
			failure = error
			if steps.dispatched, InputActivity.current() != initial {
				cleanupAllowed = false
				activity = nil
			}
		}

		if failure == nil {
			if InputActivity.current() != initial {
				failure = Refusal("DESKTOP_ACTION_FAILED", "Modifier-click detected newer shared input while focusing its target.", hint: "Observe the shared desktop before deciding whether to retry.")
				cleanupAllowed = false
				activity = nil
			} else if let cursor = CGEvent(source: nil)?.location {
				original = cursor
				do {
					guard focusState() == targetState else {
						throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click exact foreground ownership changed before click dispatch.")
					}
					try requireClickRoute(point, target: target)
					guard InputActivity.current() == initial else {
						cleanupAllowed = false
						throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click physical input changed during final route validation.")
					}
					clicked = true
					try postModifierClick(events, source: source, clicks: clicks, modifiers: modifiers.count)
					steps.record("global_events")
					let expected = initial.afterClick(clicks, modifiers: modifiers.count)
					// The combined session's counters can trail this source's by a millisecond or so; until they catch
					// up, the restore checks would take the click for someone else's input.
					let settle = Date().addingTimeInterval(0.1)
					while InputActivity.current() != expected, Date() < settle { Thread.sleep(forTimeInterval: 0.002) }
					activity = expected
				} catch let error as Dispatched {
					failure = error
					cleanupAllowed = false
				} catch {
					failure = error
				}
			} else {
				failure = Refusal("DESKTOP_ACTION_FAILED", "Modifier-click could not recapture the physical cursor immediately before clicking.")
			}
		}

		var cleanup: [String] = []
		var cursor = Restoration.notNeeded
		if cleanupAllowed, clicked, let original, let owned = activity {
			do {
				cursor = try restoreCursor(original, lastWritten: point, activity: owned)
				if cursor == .restored {
					steps.record("global_events")
					activity = owned.afterMove()
				}
			} catch let error as Dispatched {
				cleanup.append("Cursor restoration: \(error.message)")
			} catch {
				cleanup.append("Cursor restoration: \(error)")
			}
		}
		var focusRestoration = Restoration.notNeeded
		if cleanupAllowed, let owned = activity, InputActivity.current() == owned {
			do {
				focusRestoration = try restoreFocus(prior: prior, priorWindow: priorWindow, target: target, activity: owned, steps: &steps)
			} catch let error as Dispatched {
				cleanup.append("Focus restoration: \(error.message)")
			} catch {
				cleanup.append("Focus restoration: \(error)")
			}
		} else if cleanupAllowed, clicked {
			focusRestoration = .preservedNewerState
		}

		if !cleanup.isEmpty {
			if let failure { cleanup.insert("Primary action: \(describe(failure))", at: 0) }
			return unfinished(steps, Dispatched(
				message: "Modifier-click cleanup did not fully restore the shared desktop.",
				hint: "Inspect the shared desktop state before taking another input action.", cause: cleanup.joined(separator: " ")
			))
		}
		if let failure {
			if !steps.dispatched, let refusal = failure as? Refusal { throw refusal }
			return unfinished(steps, Dispatched(message: "Modifier-click failed after foreground setup began.", cause: describe(failure)))
		}
		var delivery = steps.outcome(.dispatchedUnverified, evidence: "delivery_accepted")
		delivery.unverified = true
		delivery.fields = [
			("cursor_restoration", JSON(cursor.rawValue)), ("focus_restoration", JSON(focusRestoration.rawValue)),
			("error", .object([
				("code", "DESKTOP_ACTION_UNVERIFIED"),
				("message", JSON("The click was sent as real pointer input holding \(modifiers.joined(separator: " and ")), which activated the app and moved the pointer, then restored them (pointer \(cursor.rawValue), focus \(focusRestoration.rawValue)). Its effect can't be confirmed.")),
				("hint", "Inspect the window to see what the click did, such as which items are selected. Never repeat the click blindly."),
			])),
		]
		return delivery
	}

	/// Input that went out before a failure: unknown, with the steps it dispatched and the failure as its error.
	private static func unfinished(_ steps: Steps, _ failure: Dispatched) -> Delivery {
		var delivery = steps.outcome(.indeterminate, evidence: "completion_unknown")
		var error: [(String, JSON)] = [("code", "DESKTOP_ACTION_FAILED"), ("message", JSON(failure.message)), ("hint", JSON(failure.hint))]
		if let cause = failure.cause { error.append(("cause", JSON(cause))) }
		delivery.fields = [("error", .object(error))]
		return delivery
	}

	private static func describe(_ error: Error) -> String {
		(error as? Refusal)?.message ?? (error as? Dispatched).map { [$0.message, $0.cause].compactMap(\.self).joined(separator: " ") } ?? String(describing: error)
	}

	/// The modifiers down, the clicks with their flags, then the modifiers up in reverse, all tagged with one marker.
	private static func modifierClickEvents(at point: CGPoint, clicks: Int, modifiers: [String], source: CGEventSource) -> [CGEvent] {
		let keys: [(CGKeyCode, CGEventFlags)] = modifiers.map {
			switch $0 {
			case "command": (0x37, .maskCommand)
			case "shift": (0x38, .maskShift)
			default: (0x3A, .maskAlternate)
			}
		}
		let marker = Int64.random(in: 1...Int64.max)
		var events: [CGEvent] = []
		var flags = CGEventFlags()
		func add(_ event: CGEvent?) {
			guard let event else { return }
			event.flags = flags
			event.setIntegerValueField(.eventSourceUserData, value: marker)
			events.append(event)
		}
		for (code, flag) in keys {
			flags.insert(flag)
			add(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true))
		}
		for state in 1...clicks {
			for type in [CGEventType.leftMouseDown, .leftMouseUp] {
				let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
				event?.setIntegerValueField(.mouseEventClickState, value: Int64(state))
				add(event)
			}
		}
		for (code, flag) in keys.reversed() {
			flags.remove(flag)
			add(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false))
		}
		return events
	}

	/// Posts the click and waits until the session has seen every mouse-up and modifier key-up from this source.
	private static func postModifierClick(_ events: [CGEvent], source: CGEventSource, clicks: Int, modifiers: Int) throws {
		let state = source.sourceStateID
		func counts() -> (UInt32, UInt32) {
			(CGEventSource.counterForEventType(state, eventType: .leftMouseUp), CGEventSource.counterForEventType(state, eventType: .flagsChanged))
		}
		let baseline = counts()
		withExtendedLifetime(source) { events.forEach { $0.post(tap: .cghidEventTap) } }
		let deadline = Date().addingTimeInterval(0.5)
		repeat {
			let now = counts()
			if now.0 &- baseline.0 >= UInt32(clicks), now.1 &- baseline.1 >= UInt32(modifiers * 2) { return }
			CFRunLoopRunInMode(.defaultMode, 0.005, true)
		} while Date() < deadline
		throw Dispatched(
			message: "Modifier-click mouse-up or modifier key-up delivery did not reach the session.",
			hint: "Inspect the shared desktop state before taking another input action."
		)
	}

	/// The target window must be on screen at the point, and Accessibility must find the point in it.
	private static func requireClickRoute(_ point: CGPoint, target: WindowKey) throws {
		let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
		let onScreen = rows.contains { row in
			guard row[kCGWindowNumber as String] as? Int == target.windowID, (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
			      let raw = row[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw)
			else { return false }
			return bounds.contains(point) && bounds == target.bounds && row[kCGWindowOwnerPID as String] as? pid_t == target.pid
		}
		guard onScreen else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click exact target has no provable on-screen WindowServer row.", hint: "Observe the exact target again before retrying.")
		}
		let system = AXUIElementCreateSystemWide()
		AXUIElementSetMessagingTimeout(system, 1)
		var hit: AXUIElement?
		guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit,
		      let pid = AX.pid(hit), let id = AX.owningWindowID(hit, pid: pid), let owner = Mac.window(id)
		else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click point has no provable Accessibility receiver.", hint: "Observe the exact target again before retrying.")
		}
		guard current(target) else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click exact-window identity changed before event dispatch.", hint: "Observe the exact target again before retrying.")
		}
		guard id == target.windowID, owner.pid == target.pid else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Modifier-click exact target or Accessibility receiver changed before dispatch.", hint: "Observe the exact target again before retrying.")
		}
	}

	/// Gives focus back to the window that had it, unless something newer than this click took focus since.
	private static func restoreFocus(prior: (pid: pid_t, generation: UInt64), priorWindow: WindowKey, target: WindowKey, activity: InputActivity, steps: inout Steps) throws -> Restoration {
		if focusedWindow() == priorWindow { return .notNeeded }
		guard priorWindow != target else { return .preservedNewerState }
		guard let now = focusState() else {
			throw Dispatched(message: "Modifier-click could not restore the prior foreground window or application.", cause: "The prior foreground window or application could not be re-established.")
		}
		guard now.pid == target.pid, now.window == nil || now.window == target else { return .preservedNewerState }
		let before = steps.units
		do {
			try focus(priorWindow, steps: &steps) {
				guard InputActivity.current() == activity else { throw Refusal("DESKTOP_ACTION_FAILED", "Newer foreground state replaced the target before restoration dispatch.") }
			}
		} catch let refusal as Refusal {
			// Newer input owns the desktop now; it wins over restoration.
			_ = refusal
			return .preservedNewerState
		} catch is Dispatched where steps.units == before {
			return .preservedNewerState
		}
		guard focusedWindow() == priorWindow else {
			throw Dispatched(message: "Modifier-click could not restore the prior foreground window or application.", cause: "The prior foreground window or application could not be re-established.")
		}
		return .restored
	}

	// MARK: Foreground drag

	/// A drag with the real pointer and keys: rest on the start, hold the modifiers, press, move, rest on the end,
	/// release. Exact-window events can't leave their window or hold keys for the system, so this one can.
	public static func foregroundDrag(from start: CGPoint, through waypoints: [CGPoint], to end: CGPoint, button: CGMouseButton, milliseconds: Int, modifiers: [String]) -> Delivery {
		glide(to: start, milliseconds: 200, steps: 12)
		let steps = max(10, min(120, milliseconds / 16), (waypoints.count + 1) * 4)
		let path = waypoints.isEmpty
			? (1...steps).map { step in
				let t = CGFloat(step) / CGFloat(steps)
				return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
			}
			: polyline([start] + waypoints + [end], steps: steps)
		let keys: [(CGKeyCode, CGEventFlags)] = modifiers.map {
			switch $0 {
			case "command": (0x37, .maskCommand)
			case "shift": (0x38, .maskShift)
			case "control": (0x3B, .maskControl)
			default: (0x3A, .maskAlternate)
			}
		}
		let source = CGEventSource(stateID: .hidSystemState)
		var flags = CGEventFlags()
		let downs = keys.map { code, flag in
			flags.insert(flag)
			let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
			event?.flags = flags
			return event
		}
		let ups = keys.reversed().map { code, flag in
			flags.remove(flag)
			let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
			event?.flags = flags
			return event
		}
		let (down, dragged, up): (CGEventType, CGEventType, CGEventType) = button == .right
			? (.rightMouseDown, .rightMouseDragged, .rightMouseUp) : (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
		downs.forEach { $0?.post(tap: .cghidEventTap) }
		CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: start, mouseButton: button)?.post(tap: .cghidEventTap)
		// Drag and drop between windows needs a beat after the press, and the destination needs updates while the
		// pointer rests over it before the release.
		Thread.sleep(forTimeInterval: 0.15)
		let delay = path.count > 1 ? Double(milliseconds) / 1000 / Double(path.count - 1) : 0
		var last = start
		for (index, point) in path.enumerated() {
			CGEvent(mouseEventSource: nil, mouseType: dragged, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
			last = point
			if index < path.count - 1 { Thread.sleep(forTimeInterval: delay) }
		}
		for _ in 0..<3 {
			Thread.sleep(forTimeInterval: 0.05)
			CGEvent(mouseEventSource: nil, mouseType: dragged, mouseCursorPosition: end, mouseButton: button)?.post(tap: .cghidEventTap)
		}
		CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: last, mouseButton: button)?.post(tap: .cghidEventTap)
		ups.forEach { $0?.post(tap: .cghidEventTap) }
		var delivery = Delivery(state: .dispatchedUnverified, mechanism: "global_events", evidence: "delivery_accepted", units: 1)
		delivery.mode = "foreground"
		return delivery
	}

	/// Moves the real pointer in a straight line over the duration.
	static func glide(to point: CGPoint, milliseconds: Int, steps: Int) {
		let start = CGEvent(source: nil)?.location ?? point
		for step in 1...steps {
			let t = CGFloat(step) / CGFloat(steps)
			let at = CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)
			CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
			if step < steps { Thread.sleep(forTimeInterval: Double(milliseconds) / 1000 / Double(steps - 1)) }
		}
	}
}
