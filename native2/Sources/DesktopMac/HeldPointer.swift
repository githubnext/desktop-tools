import CoreGraphics
import DesktopProtocol
import Foundation

// Press and hold in one window, ported from Peekaboo's ExactWindowHeldPointerLifecycle and
// WindowRoutedPointerDriver's held pointer (MIT).

extension Mac {
	/// Presses at a point in the window, holds for the duration while watching the window, and always releases:
	/// early, when the window changes or its process goes, and to the same process generation only.
	public static func press(at point: CGPoint, button: CGMouseButton, milliseconds: Int, window: ClickWindow) throws -> Delivery {
		guard window.bounds.contains(point) else {
			throw Refusal("DESKTOP_ACTION_FAILED", "Held pointer point is outside the exact target window bounds")
		}
		var router = try Router(window)
		let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
		let group = Router.newGroup()
		do {
			guard let primer = router.mouse(.mouseMoved, at: point, button: .left, clickState: 0) else { throw Router.Interrupted() }
			try router.post(primer, at: point, group: group)
			Thread.sleep(forTimeInterval: 0.012)
			guard let press = router.mouse(down, at: point, button: button, clickState: 1) else { throw Router.Interrupted() }
			try router.post(press, at: point, group: group)
		} catch is Router.Interrupted {
			return Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: router.posted)
		}

		// The hold ends at its planned release, or as soon as the window changes or the process goes.
		var reason = "released"
		let deadline = ContinuousClock.now + .milliseconds(milliseconds)
		while ContinuousClock.now < deadline {
			let left = (deadline - ContinuousClock.now).components
			Thread.sleep(forTimeInterval: min(0.02, max(0, Double(left.seconds) + Double(left.attoseconds) / 1e18)))
			if generation(window.pid) != window.generation { reason = "processGenerationChanged"; break }
			if (try? window.check()) == nil { reason = "windowChanged"; break }
		}

		// A recycled PID never gets the release: a new process didn't receive the press.
		guard generation(window.pid) == window.generation, let release = router.mouse(up, at: point, button: button, clickState: 1) else {
			var delivery = Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: router.posted)
			delivery.fields = [("release", JSON(reason)), ("error", .object([
				("code", "DESKTOP_ACTION_FAILED"), ("message", "Held pointer cleanup did not complete"),
				("hint", "The original target generation must be inspected before any further pointer input."),
				("cause", "The original process generation disappeared; mouse-up was not sent to a recycled PID"),
			]))]
			return delivery
		}
		// The release ignores window drift: the same process generation received the press.
		release.location = point
		release.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(window.pid))
		for field in [51, 91, 92] {
			release.setIntegerValueField(CGEventField(rawValue: UInt32(field))!, value: Int64(window.windowID))
		}
		release.setIntegerValueField(CGEventField(rawValue: 58)!, value: group)
		router.setWindowLocation(release, CGPoint(x: point.x - window.bounds.minX, y: point.y - window.bounds.minY))
		if router.usesSkyLight { skyLight.postToPid!(window.pid, release) } else { release.postToPid(window.pid) }

		var delivery = Delivery.accepted("window_targeted_events")
		delivery.fields = [("release", JSON(reason))]
		if reason != "released" {
			delivery.unverified = true
			delivery.fields.append(("error", .object([
				("code", "DESKTOP_ACTION_UNVERIFIED"),
				("message", JSON("The press ended before its planned release (\(reason)); the button was released by cleanup.")),
				("hint", "Inspect the target before retrying; the action may already have happened."),
			])))
		}
		return delivery
	}
}
