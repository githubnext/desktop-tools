import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DesktopProtocol
import Foundation

// Opt-in foreground typing and scrolling (#177, #197): the target window is brought forward, real key or
// scroll-wheel events go to it, and the pointer and the previously focused window are given back, under the same
// rules as a modifier click. Nothing confirms what the receiver did with the input, so each result is unknown and
// carries what the host read back afterward.

/// What a foreground action posted, so the session's input counters can tell it apart from anyone else's input.
struct Posted {
	var keyDown: UInt32 = 0
	var keyUp: UInt32 = 0
	var moved: UInt32 = 0
	var scrollWheel: UInt32 = 0
	/// Where the pointer was before the action moved it, and where it left it.
	var pointer: (original: CGPoint, written: CGPoint)?

	func applied(to activity: InputActivity) -> InputActivity {
		var next = activity
		next.keyDown &+= keyDown
		next.keyUp &+= keyUp
		next.moved &+= moved
		next.scrollWheel &+= scrollWheel
		return next
	}
}

extension Mac {
	/// Brings the exact window forward, runs `send`, then restores the pointer and the prior focused window while no
	/// newer input has arrived. `send` throws a Refusal only before it posts anything.
	static func inForeground(_ window: ClickWindow, action: String, send: (_ steps: inout Steps) throws -> Posted) throws -> Delivery {
		let target = WindowKey(window)
		guard current(target) else { throw Refusal("DESKTOP_ACTION_FAILED", "The window moved or closed since the snapshot. Inspect it again.") }
		guard CGPreflightPostEventAccess() else {
			var refusal = Refusal("DESKTOP_ACTION_FAILED", "Foreground \(action) needs permission to post input events.", hint: "Grant Desktop Tools Accessibility access, then retry.")
			refusal.reason = "permission_denied"
			throw refusal
		}
		guard let prior = frontmost(), let priorWindow = focusedWindow() else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Foreground \(action) could not capture the frontmost window to give focus back to afterward, so nothing was sent.")
		}
		let initial = InputActivity.current()
		guard !initial.hasHeldInput else {
			throw Refusal("DESKTOP_ACTION_FAILED", "A key or mouse button is held down, so foreground \(action) waits for it to be released. Nothing was sent.", hint: "Retry from a fresh observation once input is released.")
		}
		let targetState = FocusState(pid: target.pid, generation: target.generation, window: target)
		var steps = Steps()
		do {
			try focus(target, steps: &steps) {
				guard InputActivity.current() == initial else {
					throw Refusal("DESKTOP_ACTION_FAILED", "Someone used the keyboard or pointer while the window was being brought forward, so foreground \(action) stopped.")
				}
			}
			guard focusState() == targetState, current(target) else {
				throw Refusal("DESKTOP_ACTION_FAILED", "The window didn't become the frontmost focused window, so foreground \(action) stopped.")
			}
			guard InputActivity.current() == initial else {
				throw Refusal("DESKTOP_ACTION_FAILED", "Someone used the keyboard or pointer while the window was being brought forward, so foreground \(action) stopped.")
			}
		} catch {
			if !steps.dispatched, let refusal = error as? Refusal { throw refusal }
			return stopped(steps, "Foreground \(action) brought the app forward but stopped before sending input.", cause: describeFailure(error))
		}

		var failure: Error?
		var posted = Posted()
		do { posted = try send(&steps) } catch { failure = error }
		if let refusal = failure as? Refusal, !steps.dispatched { throw refusal }
		// The combined session's counters trail the posted events a little; wait for them before comparing.
		var owned = posted.applied(to: initial)
		let settle = Date().addingTimeInterval(0.15)
		while InputActivity.current() != owned, Date() < settle { Thread.sleep(forTimeInterval: 0.003) }
		let ours = InputActivity.current() == owned

		var cleanup: [String] = []
		var cursor = Restoration.notNeeded
		if let pointer = posted.pointer {
			if ours {
				do {
					cursor = try restoreCursor(pointer.original, lastWritten: pointer.written, activity: owned)
					if cursor == .restored { owned = owned.afterMove() }
				} catch { cleanup.append("Pointer: \(describeFailure(error))") }
			} else {
				cursor = .preservedNewerState
			}
		}
		var focusBack = Restoration.preservedNewerState
		if ours, InputActivity.current() == owned {
			do {
				focusBack = try restoreFocus(prior: prior, priorWindow: priorWindow, target: target, activity: owned, steps: &steps)
			} catch { cleanup.append("Focus: \(describeFailure(error))") }
		}
		if let failure {
			return stopped(steps, "Foreground \(action) stopped after it started sending input.", cause: ([describeFailure(failure)] + cleanup).joined(separator: " "))
		}
		var delivery = steps.outcome(.dispatchedUnverified, evidence: "delivery_accepted")
		delivery.unverified = true
		delivery.fields = [("cursor_restoration", JSON(cursor.rawValue)), ("focus_restoration", JSON(focusBack.rawValue))]
		if !cleanup.isEmpty { delivery.fields.append(("cleanup", JSON(cleanup.joined(separator: " ")))) }
		return delivery
	}

	private static func stopped(_ steps: Steps, _ message: String, cause: String) -> Delivery {
		var delivery = steps.outcome(.indeterminate, evidence: "completion_unknown")
		delivery.fields = [("error", .object([
			("code", "DESKTOP_ACTION_FAILED"), ("message", JSON(message)), ("cause", JSON(cause)),
			("hint", "Inspect the window before deciding whether to retry; some input may have arrived."),
		]))]
		return delivery
	}

	private static func describeFailure(_ error: Error) -> String {
		if let refusal = error as? Refusal { return refusal.message }
		if let dispatched = error as? Dispatched { return [dispatched.message, dispatched.cause].compactMap(\.self).joined(separator: " ") }
		return String(describing: error)
	}

	// MARK: Typing

	/// Types text with real key events into the window's keyboard focus once it is frontmost. When the snapshot saw
	/// a focused control, focus must be back on it (asked for through Accessibility if it moved); the field's value
	/// afterward is returned as `read_back`.
	public static func foregroundType(_ text: String, target: KeyboardTarget, control: AXUIElement?) throws -> Delivery {
		let window = target.window
		var readFrom: AXUIElement?
		var delivery = try inForeground(window, action: "typing") { steps in
			var focused: AXUIElement
			do { focused = try requireKeyboardFocus(target) } catch {
				guard let control, target.focusedRole != nil else { throw error }
				AXUIElementSetAttributeValue(control, kAXFocusedAttribute as CFString, kCFBooleanTrue)
				Thread.sleep(forTimeInterval: 0.1)
				focused = try requireKeyboardFocus(target)
			}
			if secureFocus(focused) { throw secureFocusRefusal }
			if IsSecureEventInputEnabled() {
				throw Refusal("DESKTOP_ACTION_FAILED", "Secure keyboard entry is on, so typed text can't be delivered. Nothing was typed.", fromHost: false)
			}
			readFrom = focused
			guard let source = CGEventSource(stateID: .privateState) else { throw Refusal("DESKTOP_ACTION_FAILED", "Foreground typing could not create its event source. Nothing was typed.") }
			var posted = Posted()
			for character in text {
				// Stop if the app lost the front, so no key reaches another app.
				guard frontmost()?.pid == window.pid else {
					if posted.keyDown == 0 { throw Refusal("DESKTOP_ACTION_FAILED", "The app lost the front before typing began. Nothing was typed.") }
					throw Dispatched(message: "The app lost the front after \(posted.keyDown) characters, so typing stopped.")
				}
				let units = Array(String(character).utf16)
				for down in [true, false] {
					guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
					event.flags = []
					event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
					event.post(tap: .cghidEventTap)
					if down { posted.keyDown += 1 } else { posted.keyUp += 1 }
					usleep(down ? 1500 : 3000)
				}
			}
			steps.record("global_events", units: Int(posted.keyDown))
			usleep(30_000)
			return posted
		}
		if let readFrom, let value = settledValue(readFrom) { delivery.fields.append(("read_back", JSON(value))) }
		return delivery
	}

	/// The control's value once it has held still for 300 ms, within 1.5 s.
	private static func settledValue(_ element: AXUIElement) -> String? {
		let start = ContinuousClock.now
		var last = AX.string(element, kAXValueAttribute)
		var changed = start
		while ContinuousClock.now < start + .milliseconds(1500), ContinuousClock.now < changed + .milliseconds(300) {
			Thread.sleep(forTimeInterval: 0.03)
			let value = AX.string(element, kAXValueAttribute)
			if value != last { last = value; changed = ContinuousClock.now }
		}
		return last
	}

	// MARK: Scrolling

	/// Scroll-wheel ticks with the real pointer at a point in the window once it is frontmost, reporting in
	/// `content_moved` whether content under the point moved.
	public static func foregroundScroll(at point: CGPoint, direction: ScrollDirection, amount: Int, window: ClickWindow) throws -> Delivery {
		guard window.bounds.contains(point) else { throw Refusal("POINT_OUTSIDE_WINDOW", "The point is outside the exact window.") }
		let app = AXUIElementCreateApplication(window.pid)
		AXUIElementSetMessagingTimeout(app, 1)
		var hit: AXUIElement?
		_ = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
		let root = hit.map { webArea(of: $0) ?? scrollContainer(of: $0) ?? $0 }
		let before = root.map(landmarks) ?? []
		var delivery = try inForeground(window, action: "scrolling") { steps in
			guard exposes(point, window: window) else {
				throw Refusal("TARGET_OCCLUDED", "Another window covers that point even with the app in front. Nothing was scrolled.")
			}
			guard let original = CGEvent(source: nil)?.location, let source = CGEventSource(stateID: .privateState) else {
				throw Refusal("DESKTOP_ACTION_FAILED", "Foreground scrolling could not read the pointer. Nothing was scrolled.")
			}
			var posted = Posted()
			CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
			posted.moved += 1
			posted.pointer = (original, point)
			steps.record("global_events")
			Thread.sleep(forTimeInterval: 0.05)
			let dy: Int32 = direction == .up ? 1 : direction == .down ? -1 : 0
			let dx: Int32 = direction == .left ? 1 : direction == .right ? -1 : 0
			for tick in 0..<amount {
				if tick > 0 { Thread.sleep(forTimeInterval: 0.012) }
				guard frontmost()?.pid == window.pid, let at = CGEvent(source: nil)?.location, hypot(at.x - point.x, at.y - point.y) <= 1 else {
					throw Dispatched(message: "The app lost the front or the pointer moved after \(tick) of \(amount) wheel ticks, so scrolling stopped.")
				}
				guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { continue }
				event.location = point
				event.post(tap: .cghidEventTap)
				posted.scrollWheel += 1
			}
			steps.record("global_events", units: Int(posted.scrollWheel))
			return posted
		}
		if !before.isEmpty { delivery.fields.append(("content_moved", JSON(scrolled(before, direction: direction)))) }
		return delivery
	}

	private static func scrollContainer(of element: AXUIElement) -> AXUIElement? {
		var current = element
		for _ in 0..<32 {
			switch AX.string(current, kAXRoleAttribute) {
			case "AXScrollArea": return current
			case "AXWindow", "AXApplication", nil: return nil
			default: break
			}
			guard let parent = AX.element(AX.value(current, kAXParentAttribute)) else { return nil }
			current = parent
		}
		return nil
	}
}
