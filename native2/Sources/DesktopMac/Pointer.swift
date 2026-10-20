import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// Background clicks, ported from Peekaboo's ClickService, ActionInputDriver, BackgroundInputDriver and
// WindowRoutedPointerDriver (MIT). A single left click is always an Accessibility action, even at a point;
// real pointer events go only to the exact window's process, never through the HID tap, so the pointer
// doesn't move and the app isn't brought forward.

/// What one delivery did, as Peekaboo's DesktopActionOutcome reports it.
public struct Delivery: Sendable {
	public enum State: String, Sendable {
		case confirmedChange = "confirmed_change"
		case confirmedNoChange = "confirmed_no_change"
		case dispatchedUnverified = "dispatched_unverified"
		case indeterminate
	}

	public let state: State
	public let mechanism: String?
	public let evidence: String
	public let units: Int?
	/// Fields the action result adds, such as which receiver got keys.
	public var fields: [(String, JSON)] = []

	public init(state: State, mechanism: String?, evidence: String, units: Int?) {
		self.state = state
		self.mechanism = mechanism
		self.evidence = evidence
		self.units = units
	}

	public static func accepted(_ mechanism: String, units: Int = 1) -> Delivery {
		Delivery(state: .dispatchedUnverified, mechanism: mechanism, evidence: "delivery_accepted", units: units)
	}

	/// Set when a tool demands more than delivery, as web typing demands a read-back.
	public var unverified = false

	/// foreground for input through the real pointer.
	public var mode = "background"

	/// completed, or unknown when the input may not have finished.
	public var outcome: String {
		unverified || state == .indeterminate || evidence == "operation_still_running" ? "unknown" : "completed"
	}

	public var json: JSON {
		let confirmed = state == .confirmedChange || state == .confirmedNoChange
		return .object([
			"state": JSON(state.rawValue),
			"effect": JSON(confirmed ? "confirmed" : "unverifiable"),
			"route": "local",
			"delivery_mechanism": mechanism.map(JSON.string),
			"delivery_mode": mechanism == nil ? nil : JSON(mode),
			"evidence": JSON(evidence),
			"dispatch_state": JSON(state == .confirmedNoChange ? "none" : state == .indeterminate ? "may_have_dispatched" : "dispatched"),
			"dispatched_unit_count": units.map { JSON($0) },
			"retry_safety": JSON(confirmed ? "not_applicable" : "unsafe"),
			"escalation": JSON(confirmed ? "none" : "observe_before_retry"),
		])
	}
}

/// The route can't deliver this click; the caller tries the next one.
public struct Unsupported: Error {}

/// Refused before any input, with Peekaboo's error code.
public struct Refusal: Error {
	public let code: String
	public let message: String
	public let hint: String?
	public let cause: String?
	/// Whether the result carries the refused native outcome, as host refusals do; the native client's own
	/// checks refuse without one.
	public let fromHost: Bool
	public init(_ code: String, _ message: String, hint: String? = nil, cause: String? = nil, fromHost: Bool = true) {
		self.code = code
		self.message = message
		self.hint = hint
		self.cause = cause
		self.fromHost = fromHost
	}

	/// target_unavailable, or operation_unsupported when no route exists for this kind of target.
	public var reason = "target_unavailable"

	/// The host's refused outcome.
	public var outcome: JSON {
		.object([
			("state", "refused"), ("effect", "refused"), ("route", "local"), ("evidence", "request_refused"),
			("dispatch_state", "none"), ("retry_safety", "safe"),
			("escalation", JSON(reason == "operation_unsupported" ? "correct_request" : "refresh_target")),
			("refusal_reason", JSON(reason)),
		])
	}
}

public enum ClickKind: String, Sendable {
	case single, double, right, middle, triple
}

/// The window a click must land in, as the snapshot observed it.
public struct ClickWindow: Sendable {
	public let pid: pid_t
	public let generation: UInt64
	public let windowID: Int
	public let bounds: CGRect
	public init(pid: pid_t, generation: UInt64, windowID: Int, bounds: CGRect) {
		self.pid = pid
		self.generation = generation
		self.windowID = windowID
		self.bounds = bounds
	}

	/// Same process generation, and the same window at exactly the same place.
	public func check() throws {
		guard Mac.generation(pid) == generation, let now = Mac.window(windowID), now.pid == pid, now.bounds == bounds else {
			throw Refusal("SNAPSHOT_STALE", "Snapshot is stale: the exact window changed since it was inspected. Inspect it again.")
		}
	}
}

private let textInputRoles: Set<String> = ["AXTextField", "AXTextArea"]
private let focusableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
private let containerRoles: Set<String> = [
	"AXApplication", "AXGroup", "AXLayoutArea", "AXRadioGroup", "AXScrollArea", "AXWebArea", "AXWindow",
]

extension Mac {
	// MARK: Accessibility routes

	/// An element click as Peekaboo's action route performs it: focus a text input, else AXPress, else
	/// focus whatever accepts it. Throws Unsupported when none applies.
	public static func clickElement(_ element: AXUIElement, window: ClickWindow) throws -> Delivery {
		AXUIElementSetMessagingTimeout(element, 1)
		let role = AX.string(element, kAXRoleAttribute) ?? ""
		if textInputRoles.contains(role), settable(element, kAXFocusedAttribute) {
			return try focus(element, window: window)
		}
		if actions(element).contains(kAXPressAction) {
			return try press(element, window: window)
		}
		if focusableRoles.contains(role) && settable(element, kAXFocusedAttribute) || settable(element, kAXValueAttribute) {
			return try focus(element, window: window)
		}
		throw Unsupported()
	}

	/// A single left click at a global point: the Accessibility element there, its descendants under the
	/// point, then its ancestors, choosing the first that can be focused, pressed or selected.
	public static func clickPoint(_ point: CGPoint, window: ClickWindow) throws -> Delivery {
		let app = AXUIElementCreateApplication(window.pid)
		AXUIElementSetMessagingTimeout(app, 1)
		var hit: AXUIElement?
		guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit else {
			throw Refusal("ELEMENT_NOT_FOUND", "No Accessibility element is at that point in the window.")
		}
		var candidates = [hit] + descendants(of: hit, containing: point)
		var parent = hit
		for _ in 0..<8 {
			guard let next = AX.element(AX.value(parent, kAXParentAttribute)) else { break }
			candidates.append(next)
			parent = next
		}
		let roles = candidates.map { AX.string($0, kAXRoleAttribute) ?? "" }
		let enabled = candidates.map { (AX.value($0, kAXEnabledAttribute) as? Bool) != false }
		let pick: (AXUIElement, String)? = {
			for (i, element) in candidates.enumerated() where enabled[i] && textInputRoles.contains(roles[i]) && settable(element, kAXFocusedAttribute) {
				return (element, "focus")
			}
			for (i, element) in candidates.enumerated() where enabled[i] && !containerRoles.contains(roles[i]) && actions(element).contains(kAXPressAction) {
				return (element, "press")
			}
			for (i, element) in candidates.enumerated() where roles[i] == "AXRow" && settable(element, kAXSelectedAttribute) {
				return (element, "select")
			}
			for (i, element) in candidates.enumerated() where enabled[i] && focusableRoles.contains(roles[i]) && settable(element, kAXFocusedAttribute) {
				return (element, "focus")
			}
			return nil
		}()
		guard let (element, how) = pick else {
			throw Refusal("DESKTOP_ACTION_FAILED", "No pressable accessibility element was found at (\(Int(point.x)), \(Int(point.y))) in PID \(window.pid). Background clicks press the accessibility element at the target point, and nothing pressable was found there — the point may be empty, a custom-drawn view, or an element that exposes no press action. Nothing was clicked. Inspect again and click an element, or click with a modifier to send a real pointer click in the foreground.")
		}
		// Only the same app's other windows are caught here; another app's window on top is not.
		if let owner = AX.element(AX.value(element, kAXWindowAttribute)), let id = AX.windowID(owner), id != window.windowID {
			throw Refusal("TARGET_OCCLUDED", "Another window of this app covers that point. Inspect the window on top instead.")
		}
		switch how {
		case "focus": return try focus(element, window: window)
		case "press": return try press(element, window: window)
		default:
			try window.check()
			let error = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
			guard error == .success else { return Delivery(state: .indeterminate, mechanism: "accessibility_value", evidence: "completion_unknown", units: 1) }
			return .accepted("accessibility_value")
		}
	}

	/// AXShowMenu, which blocks while the menu is open; a menu still open after half a second is still running.
	public static func showMenu(_ element: AXUIElement, window: ClickWindow) throws -> Delivery {
		guard actions(element).contains("AXShowMenu") else { throw Unsupported() }
		try window.check()
		let done = DispatchSemaphore(value: 0)
		let result = Locked<AXError?>(nil)
		let reference = UncheckedBox(element)
		Thread.detachNewThread {
			result.value = AXUIElementPerformAction(reference.value, "AXShowMenu" as CFString)
			done.signal()
		}
		guard done.wait(timeout: .now() + 0.5) == .success else {
			return Delivery(state: .dispatchedUnverified, mechanism: "accessibility_action", evidence: "operation_still_running", units: 1)
		}
		return try finished(result.value ?? .failure, mechanism: "accessibility_action")
	}

	private static func press(_ element: AXUIElement, window: ClickWindow) throws -> Delivery {
		try window.check()
		return try finished(AXUIElementPerformAction(element, kAXPressAction as CFString), mechanism: "accessibility_action")
	}

	private static func finished(_ error: AXError, mechanism: String) throws -> Delivery {
		switch error {
		case .success: return .accepted(mechanism)
		case .actionUnsupported: throw Unsupported()
		case .invalidUIElement:
			throw Refusal("ELEMENT_NOT_FOUND", "The element is gone from the window. Inspect it again.")
		default:
			// The app may have acted and then failed to reply in time.
			return Delivery(state: .indeterminate, mechanism: mechanism, evidence: "completion_unknown", units: 1)
		}
	}

	/// Focus a text input and read focus back, as a click into it would; AXPress can be accepted without focusing.
	private static func focus(_ element: AXUIElement, window: ClickWindow) throws -> Delivery {
		if (AX.value(element, kAXFocusedAttribute) as? Bool) == true {
			return Delivery(state: .confirmedNoChange, mechanism: nil, evidence: "verified_no_change", units: nil)
		}
		try window.check()
		let error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
		if error == .invalidUIElement { throw Refusal("ELEMENT_NOT_FOUND", "The element is gone from the window. Inspect it again.") }
		let deadline = ContinuousClock.now + .milliseconds(250)
		for _ in 0..<14 where ContinuousClock.now < deadline {
			if (AX.value(element, kAXFocusedAttribute) as? Bool) == true {
				return Delivery(state: .confirmedChange, mechanism: "accessibility_value", evidence: "verified_change", units: 1)
			}
			Thread.sleep(forTimeInterval: 0.02)
		}
		return Delivery(state: .indeterminate, mechanism: "accessibility_value", evidence: "completion_unknown", units: 1)
	}

	static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
		var value = DarwinBoolean(false)
		return AXUIElementIsAttributeSettable(element, attribute as CFString, &value) == .success && value.boolValue
	}

	static func actions(_ element: AXUIElement) -> [String] {
		var names: CFArray?
		return AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
	}

	/// Up to 256 descendants, 8 levels deep, whose frames contain the point, breadth first.
	private static func descendants(of root: AXUIElement, containing point: CGPoint) -> [AXUIElement] {
		var found: [AXUIElement] = []
		var level = [root]
		for _ in 0..<8 where !level.isEmpty && found.count < 256 {
			var next: [AXUIElement] = []
			for element in level {
				for child in AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
					guard let frame = AX.frame(child), frame.contains(point) else { continue }
					found.append(child)
					next.append(child)
					if found.count == 256 { return found }
				}
			}
			level = next
		}
		return found
	}

	// MARK: Window-routed pointer events

	/// Double, triple, right and middle clicks as real mouse events posted to the window's process with
	/// the window under the pointer named, so the app handles them in that window without activating.
	public static func routedClick(at point: CGPoint, kind: ClickKind, window: ClickWindow) throws -> Delivery {
		guard window.bounds.contains(point) else {
			throw Refusal("POINT_OUTSIDE_WINDOW", "The point is outside the exact window.")
		}
		var router = try Router(window)
		let (button, down, up): (CGMouseButton, CGEventType, CGEventType) = switch kind {
		case .right: (.right, .rightMouseDown, .rightMouseUp)
		case .middle: (.center, .otherMouseDown, .otherMouseUp)
		default: (.left, .leftMouseDown, .leftMouseUp)
		}
		let count = kind == .double ? 2 : kind == .triple ? 3 : 1
		let group = Router.newGroup()
		func post(_ type: CGEventType, clickState: Int64) throws {
			guard let event = router.mouse(type, at: point, button: button, clickState: clickState) else { throw Router.Interrupted() }
			try router.post(event, at: point, group: group)
		}
		do {
			try post(.mouseMoved, clickState: 0)
			Thread.sleep(forTimeInterval: 0.012)
			for index in 1...count {
				try post(down, clickState: Int64(index))
				Thread.sleep(forTimeInterval: 0.028)
				try post(up, clickState: Int64(index))
				if index < count { Thread.sleep(forTimeInterval: 0.08) }
			}
		} catch is Router.Interrupted {
			return Delivery(state: .indeterminate, mechanism: "window_targeted_events", evidence: "completion_unknown", units: router.posted)
		}
		// Peekaboo counts every event posted, the pointer move included.
		return .accepted("window_targeted_events", units: router.posted)
	}

	/// Chromium, Electron and Catalyst apps take routed events only through SkyLight's post.
	static func routesThroughSkyLight(_ pid: pid_t) -> Bool {
		guard let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL,
		      let info = Bundle(url: url)?.infoDictionary else { return false }
		let id = (app.bundleIdentifier ?? "").lowercased()
		if ["com.google.chrome", "org.chromium", "com.microsoft.edgemac", "com.brave.browser", "com.vivaldi", "company.thebrowser"].contains(where: id.hasPrefix) {
			return true
		}
		if (info["NSPrincipalClass"] as? String)?.lowercased().contains("atomapplication") == true || info["ElectronAsarIntegrity"] != nil {
			return true
		}
		return info["UIApplicationSceneManifest"] != nil || info["UIDeviceFamily"] != nil
	}
}

let skyLight: (setWindowLocation: (@convention(c) (CGEvent, CGPoint) -> Void)?, postToPid: (@convention(c) (pid_t, CGEvent) -> Void)?) = {
	_ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
	let location = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
	let post = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLEventPostToPid")
	return (
		location.map { unsafeBitCast($0, to: (@convention(c) (CGEvent, CGPoint) -> Void).self) },
		post.map { unsafeBitCast($0, to: (@convention(c) (pid_t, CGEvent) -> Void).self) }
	)
}()

final class Locked<T>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: T
	init(_ value: T) { stored = value }
	var value: T {
		get { lock.withLock { stored } }
		set { lock.withLock { stored = newValue } }
	}
}

final class UncheckedBox<T>: @unchecked Sendable {
	let value: T
	init(_ value: T) { self.value = value }
}
