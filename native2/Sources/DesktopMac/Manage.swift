import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// App and window management, ported from Peekaboo's ApplicationService (launch, activation, visibility, quit),
// WindowManagementService (geometry, minimize, restore, close, full screen) and FocusManagementService (MIT).
// Every mutation is pinned to the exact window or process generation the caller observed, and re-reads it
// before it acts.

private typealias SpacesConnection = Int32
@_silgen_name("_CGSDefaultConnection") private func manageDefaultConnection() -> SpacesConnection
@_silgen_name("CGSCopyManagedDisplaySpaces") private func manageCopyManagedDisplaySpaces(_ connection: SpacesConnection) -> CFArray?

/// A window target from desktop_windows, as the caller passed it back.
public struct ExactWindow: Sendable {
	public let pid: pid_t
	public let generation: UInt64
	public let id: Int
	public let bounds: CGRect
	public let isMinimized: Bool
	public init(pid: pid_t, generation: UInt64, id: Int, bounds: CGRect, isMinimized: Bool) {
		self.pid = pid
		self.generation = generation
		self.id = id
		self.bounds = bounds
		self.isMinimized = isMinimized
	}

	func with(bounds: CGRect) -> ExactWindow {
		ExactWindow(pid: pid, generation: generation, id: id, bounds: bounds, isMinimized: isMinimized)
	}
}

/// Peekaboo's DesktopActionOutcome, encoded as the native client sends it.
public enum Outcome {
	static func make(
		_ state: String, effect: String, mechanism: String? = nil, mode: String = "background", evidence: String,
		dispatch: String, units: Int? = nil, retry: String, escalation: String, refusal: String? = nil
	) -> JSON {
		.object([
			"state": JSON(state),
			"effect": JSON(effect),
			"route": "local",
			"delivery_mechanism": mechanism.map(JSON.string),
			"delivery_mode": mechanism.map { _ in JSON(mode) },
			"evidence": JSON(evidence),
			"dispatch_state": JSON(dispatch),
			"dispatched_unit_count": units.map { JSON($0) },
			"retry_safety": JSON(retry),
			"escalation": JSON(escalation),
			"refusal_reason": refusal.map(JSON.string),
		])
	}

	public static func change(_ mechanism: String, mode: String = "background", units: Int?) -> JSON {
		make("confirmed_change", effect: "confirmed", mechanism: mechanism, mode: mode, evidence: "verified_change",
		     dispatch: "dispatched", units: units, retry: "not_applicable", escalation: "none")
	}

	public static let noChange = make("confirmed_no_change", effect: "confirmed", evidence: "verified_no_change",
	                                  dispatch: "none", retry: "not_applicable", escalation: "none")

	static func unverified(_ mechanism: String, mode: String = "background", evidence: String, units: Int?) -> JSON {
		make("dispatched_unverified", effect: "unverifiable", mechanism: mechanism, mode: mode, evidence: evidence,
		     dispatch: "dispatched", units: units, retry: "unsafe", escalation: "observe_before_retry")
	}

	static func indeterminate(_ mechanism: String?, mode: String = "background", units: Int?) -> JSON {
		make("indeterminate", effect: "unverifiable", mechanism: mechanism, mode: mode, evidence: "completion_unknown",
		     dispatch: "may_have_dispatched", units: units, retry: "unsafe", escalation: "observe_before_retry")
	}

	static func noop(_ mechanism: String, mode: String = "background", units: Int?) -> JSON {
		make("suspected_noop", effect: "suspected_noop", mechanism: mechanism, mode: mode, evidence: "observed_no_change",
		     dispatch: "dispatched", units: units, retry: "safe", escalation: "refresh_target")
	}

	static func refused(_ reason: String) -> JSON {
		let escalation = switch reason {
		case "invalid_request", "foreground_consent_required", "operation_unsupported": "correct_request"
		case "permission_denied": "grant_permission"
		case "request_cancelled": "none"
		case "runtime_incompatible": "update_runtime"
		default: "refresh_target"
		}
		return make("refused", effect: "refused", evidence: "request_refused", dispatch: "none", retry: "safe",
		             escalation: escalation, refusal: reason)
	}
}

/// Peekaboo's DesktopActionFailure: an outcome with the message, hint and cause the native client reports.
public struct ManageFailure: Error, Sendable {
	public let outcome: JSON
	public let message: String
	public let hint: String?
	public let cause: String?

	init(_ outcome: JSON, _ message: String, hint: String? = nil, cause: String? = nil) {
		self.outcome = outcome
		self.message = message
		self.hint = hint
		self.cause = cause
	}

	/// The native client's refusal while the GUI session is locked.
	public static let lockedManagement = refused("target_unavailable", "The macOS GUI session is locked. Desktop management was not dispatched.",
		hint: "Unlock the active user session, then refresh desktop_apps or desktop_windows before choosing a new action.")
	public static let lockedOpening = refused("target_unavailable", "The macOS GUI session is locked. The opening operation was not dispatched.",
		hint: "Unlock the active user session before choosing a new action.")
	/// The Bridge's refusal of a window target that no longer matches its receipt.
	public static let pinnedChanged = refused("invalid_request", "Pinned window target disappeared or changed owner/process generation/bounds",
		hint: "Correct the request before retrying.")

	public var dispatched: Bool { outcome["dispatch_state"]?.string != "none" }
	public var refreshTarget: Bool { outcome["escalation"]?.string == "refresh_target" }

	static func refused(_ reason: String, _ message: String, hint: String? = nil, cause: String? = nil) -> ManageFailure {
		ManageFailure(Outcome.refused(reason), message, hint: hint, cause: cause)
	}

	/// A window action refused before dispatch, as WindowManagementActionOutcome.refused words it.
	static func refused(action: String, _ error: ServiceError) -> ManageFailure {
		let hint = switch error.reason {
		case "target_unavailable": "Refresh the exact window receipt before retrying."
		case "invalid_request": "Correct the window target or mutation receipt before retrying."
		default: "Use a window and host that support \(action)."
		}
		return refused(error.reason, error.message, hint: hint, cause: error.cause)
	}

	static func unverified(action: String, _ mechanism: String, units: Int, cause: ServiceError) -> ManageFailure {
		ManageFailure(Outcome.unverified(mechanism, evidence: "delivery_accepted", units: units),
		              "The \(action) request was accepted, but its exact result could not be verified",
		              hint: "Observe the exact window before retrying.", cause: cause.cause)
	}

	static func noop(action: String, _ mechanism: String, units: Int) -> ManageFailure {
		ManageFailure(Outcome.noop(mechanism, units: units),
		              "The \(action) request was accepted, but the exact window remained in its prior state",
		              hint: "Refresh the exact window receipt before retrying.")
	}
}

/// The PeekabooError cases these services throw: the localized message, the case as Swift prints it, and the
/// refusal reason WindowManagementActionOutcome maps it to.
struct ServiceError: Error {
	let message: String
	let cause: String
	let reason: String

	static func commandFailed(_ text: String) -> ServiceError {
		ServiceError(message: "Command failed: \(text)", cause: "commandFailed(\(quoted(text)))", reason: "target_unavailable")
	}

	static func windowNotFound(_ criteria: String) -> ServiceError {
		ServiceError(message: "Window not found: \(criteria)", cause: "windowNotFound(criteria: Optional(\(quoted(criteria))))",
		             reason: "target_unavailable")
	}

	static func invalidInput(_ text: String) -> ServiceError {
		ServiceError(message: "Invalid input: \(text)", cause: "invalidInput(\(quoted(text)))", reason: "invalid_request")
	}

	static func interactionFailed(_ action: String, _ reason: String) -> ServiceError {
		let text = "Failed to perform \(action): \(reason)"
		return ServiceError(message: text, cause: "operationError(message: \(quoted(text)))", reason: "operation_unsupported")
	}

	static func timeout(_ text: String) -> ServiceError {
		ServiceError(message: "Operation timed out: \(text)", cause: "timeout(\(quoted(text)))", reason: "operation_unsupported")
	}

	private static func quoted(_ text: String) -> String { String(reflecting: text) }
}

private let messagingTimeout: Float = 0.75

/// Runs AppKit work on the host's main thread, which runs its event loop.
private func onMain<T: Sendable>(_ work: @MainActor @Sendable () -> T) -> T {
	Thread.isMainThread ? MainActor.assumeIsolated(work) : DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
}

private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

private func boundsMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
	abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
		&& abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

extension Mac {
	// MARK: Identity

	/// Whether a running application still has this PID and process generation, as the Bridge's mutation
	/// inventory proves before any management action.
	public static func applicationMatches(pid: pid_t, generation: UInt64) -> Bool {
		let running = onMain { NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == pid && !$0.isTerminated } }
		return running && startIdentity(pid).value == generation
	}

	static func ownerGeneration(_ window: ExactWindow) -> Bool {
		window.id > 0 && window.pid > 0 && startIdentity(window.pid).value == window.generation
	}

	/// Same owner generation, and WindowServer still lists the window for that owner at exactly its bounds.
	static func pinned(_ window: ExactWindow) -> Bool {
		guard ownerGeneration(window), let now = Mac.window(window.id) else { return false }
		return now.pid == window.pid && now.bounds == window.bounds
	}

	/// The Bridge's check of a pinned window target before any window operation: unchanged, or minimized
	/// and left out of WindowServer's list.
	public static func windowTargetHolds(_ window: ExactWindow) -> Bool {
		pinned(window) || (window.isMinimized && ownerGeneration(window) && Mac.window(window.id) == nil)
	}

	/// The Accessibility window with this window number.
	static func axWindow(pid: pid_t, id: Int, timeout: Float = messagingTimeout) -> AXUIElement? {
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(app, timeout)
		guard let list = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
		for window in list {
			AXUIElementSetMessagingTimeout(window, timeout)
			if AX.windowID(window) == id { return window }
		}
		return nil
	}

	private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
		(AX.value(element, attribute) as? NSNumber)?.boolValue
	}

	/// validatePinnedWindowMutation: WindowServer can omit minimized entries, so those pass on owner generation alone.
	private static func validateMutation(_ window: ExactWindow) throws(ServiceError) {
		if pinned(window) { return }
		guard Mac.window(window.id) == nil, window.isMinimized, ownerGeneration(window) else {
			throw .commandFailed("Window \(window.id) disappeared or changed identity")
		}
	}

	/// The exact Accessibility window, checked against the receipt's number and bounds before dispatch.
	private static func pinnedElement(_ window: ExactWindow) throws(ServiceError) -> AXUIElement {
		guard let element = axWindow(pid: window.pid, id: window.id) else { throw .windowNotFound("windowId \(window.id)") }
		try validateMutation(window)
		guard ownerGeneration(window), AX.windowID(element) == window.id, AX.frame(element) == window.bounds else {
			throw .commandFailed("Window \(window.id) changed identity before native dispatch")
		}
		return element
	}

	/// Polls WindowServer until the window's bounds are within a point of `expected`, then returns them exactly.
	private static func repin(_ window: ExactWindow, to expected: CGRect, until deadline: Date) throws(ServiceError) -> CGRect {
		while Date() < deadline {
			if ownerGeneration(window), let now = Mac.window(window.id), now.pid == window.pid, boundsMatch(now.bounds, expected) {
				return now.bounds
			}
			pause(0.05)
		}
		throw .commandFailed("Window \(window.id) did not reach verified requested bounds \(expected)")
	}

	// MARK: Geometry

	public static func moveWindow(_ window: ExactWindow, to origin: CGPoint) throws(ManageFailure) -> JSON {
		try perform("move window") {
			try geometry(window, to: CGRect(origin: origin, size: window.bounds.size), action: "move window")
		}
	}

	public static func resizeWindow(_ window: ExactWindow, to size: CGSize) throws(ManageFailure) -> JSON {
		try perform("resize window") {
			try geometry(window, to: CGRect(origin: window.bounds.origin, size: size), action: "resize window")
		}
	}

	public static func maximizeWindow(_ window: ExactWindow) throws(ManageFailure) -> JSON {
		try perform("maximize window") {
			guard let current = Mac.window(window.id), current.pid == window.pid else {
				throw ServiceError.windowNotFound("No exact window identity was available for maximize")
			}
			guard let desired = maximizedFrame(for: current.bounds) else {
				throw ServiceError.commandFailed("No display is available for window maximize")
			}
			if boundsMatch(current.bounds, desired) { return Outcome.noChange }
			return try geometry(window, to: desired, action: "maximize window")
		}
	}

	/// The visible frame, in top-left coordinates, of the screen the window overlaps most, else the nearest one.
	static func maximizedFrame(for bounds: CGRect) -> CGRect? {
		let frames = onMain { () -> [CGRect] in
			let primary = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
			return NSScreen.screens.map { screen in
				let visible = screen.visibleFrame
				return CGRect(x: visible.minX, y: primary - visible.minY - visible.height, width: visible.width, height: visible.height)
			}
		}
		let area = { (rect: CGRect) in rect.isNull ? 0 : rect.width * rect.height }
		guard let best = frames.max(by: { area($0.intersection(bounds)) < area($1.intersection(bounds)) }) else { return nil }
		if area(best.intersection(bounds)) > 0 { return best }
		let center = CGPoint(x: bounds.midX, y: bounds.midY)
		let distance = { (rect: CGRect) in pow(rect.midX - center.x, 2) + pow(rect.midY - center.y, 2) }
		return frames.min { distance($0) < distance($1) }
	}

	/// Peekaboo's completePinnedWindowGeometry: the position, then the size, each written only to the exact
	/// window at its last verified bounds and read back from WindowServer before the next, within one 2 s deadline.
	private static func geometry(_ window: ExactWindow, to target: CGRect, action: String) throws(ManageFailure) -> JSON {
		let deadline = Date().addingTimeInterval(2)
		var steps: [(attribute: String, value: AXValue?, expected: CGRect)] = []
		if window.bounds.origin != target.origin {
			var origin = target.origin
			steps.append((kAXPositionAttribute, AXValueCreate(.cgPoint, &origin), CGRect(origin: target.origin, size: window.bounds.size)))
		}
		if window.bounds.size != target.size {
			var size = target.size
			steps.append((kAXSizeAttribute, AXValueCreate(.cgSize, &size), target))
		}
		func remaining() -> Float { Float(min(Double(messagingTimeout), deadline.timeIntervalSinceNow)) }
		if steps.isEmpty {
			guard ownerGeneration(window), pinned(window) || (window.isMinimized && Mac.window(window.id) == nil),
			      let element = axWindow(pid: window.pid, id: window.id, timeout: remaining()),
			      AX.pid(element) == window.pid, AX.frame(element) == window.bounds, AX.windowID(element) == window.id
			else { throw .refused(action: action, .windowNotFound("The exact unchanged window could not be verified")) }
			return Outcome.noChange
		}
		var current = window
		var writes = 0
		var unknown: ManageFailure?
		for step in steps {
			do throws(ServiceError) {
				guard remaining() > 0 else { throw .timeout("Window geometry exceeded its shared deadline") }
				guard pinned(current), let element = axWindow(pid: current.pid, id: current.id, timeout: remaining()),
				      AX.pid(element) == current.pid, AX.frame(element) == current.bounds, AX.windowID(element) == current.id,
				      let value = step.value, remaining() > 0
				else { throw .interactionFailed("window geometry", "The native geometry write was not admitted") }
				AXUIElementSetMessagingTimeout(element, remaining())
				let result = AXUIElementSetAttributeValue(element, step.attribute as CFString, value)
				if result == .cannotComplete {
					unknown = ManageFailure(Outcome.indeterminate("accessibility_value", units: writes + 1),
					                    "The \(action) request may have changed the window",
					                    hint: "Observe the exact window before retrying; native completion is unknown.",
					                    cause: ServiceError.commandFailed("The native geometry write's completion is unknown").cause)
					throw .commandFailed("The native geometry write's completion is unknown")
				}
				guard result == .success else { throw .interactionFailed("window geometry", "The native geometry write was not admitted") }
				writes += 1
				guard AX.windowID(element) == current.id, ownerGeneration(current) else {
					throw .commandFailed("Window identity changed during geometry dispatch")
				}
				current = current.with(bounds: try repin(current, to: step.expected, until: deadline))
			} catch {
				if let unknown { throw unknown }
				// An unchanged readback can't rule out a delayed, already accepted write.
				if writes == 0 { throw .refused(action: action, error) }
				throw .unverified(action: action, "accessibility_value", units: writes, cause: error)
			}
		}
		return Outcome.change("accessibility_value", units: writes)
	}

	/// Maps a service error escaping before dispatch to a refusal, as WindowManagementActionOutcome.perform does.
	private static func perform(_ action: String, _ work: () throws -> JSON) throws(ManageFailure) -> JSON {
		do { return try work() } catch let failure as ManageFailure { throw failure } catch let error as ServiceError {
			throw .refused(action: action, error)
		} catch {
			throw .refused("operation_unsupported", String(describing: error), hint: "Use a window and host that support \(action).")
		}
	}

	// MARK: Window state

	public static func minimizeWindow(_ window: ExactWindow) throws(ManageFailure) -> JSON {
		try perform("minimize window") {
			try validateMutation(window)
			let element = try pinnedElement(window)
			if bool(element, kAXMinimizedAttribute) == true { return Outcome.noChange }
			guard AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else {
				throw ServiceError.interactionFailed("minimize window", "Window minimize operation failed")
			}
			let deadline = Date().addingTimeInterval(1)
			while Date() < deadline {
				let minimized = bool(element, kAXMinimizedAttribute)
				let id = AX.windowID(element)
				let sameWindow = id == window.id ? AX.frame(element) == window.bounds : id == nil && minimized == true && pinned(window)
				guard ownerGeneration(window), sameWindow else {
					throw ManageFailure.unverified(action: "minimize window", "accessibility_value", units: 1,
					                               cause: .commandFailed("Window \(window.id) changed owner/process generation during minimize"))
				}
				if minimized == true { return Outcome.change("accessibility_value", units: 1) }
				pause(0.05)
			}
			throw ManageFailure.noop(action: "minimize window", "accessibility_value", units: 1)
		}
	}

	public static func restoreWindow(_ window: ExactWindow) throws(ManageFailure) -> JSON {
		try perform("restore window") {
			try validateMutation(window)
			if window.isMinimized {
				// Ported from Peekaboo's dispatchMinimizedRestore and completePinnedMinimizedWindowRestore.
				guard ownerGeneration(window), Mac.window(window.id) == nil || pinned(window),
				      let element = axWindow(pid: window.pid, id: window.id),
				      AX.frame(element) == window.bounds, bool(element, kAXMinimizedAttribute) == true,
				      AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
				else {
					throw ServiceError.interactionFailed("restore window", "Window restore operation failed or the exact minimized receipt became ambiguous")
				}
				do throws(ServiceError) {
					// WindowServer listing the window again at its bounds proves the restore. AXMinimized can stay
					// true until the animation ends, so Peekaboo's repinned receipt doesn't read it.
					// Within a point is still mid-animation here, so wait for the receipt's exact bounds.
					let deadline = Date().addingTimeInterval(2)
					var bounds = try repin(window, to: window.bounds, until: deadline)
					while bounds != window.bounds, Date() < deadline {
						pause(0.05)
						bounds = try repin(window, to: window.bounds, until: deadline)
					}
					guard bounds == window.bounds else {
						throw ServiceError.commandFailed("Window \(window.id) became ambiguous after restore dispatch")
					}
				} catch {
					throw ManageFailure.unverified(action: "restore window", "accessibility_value", units: 1, cause: error)
				}
				return Outcome.change("accessibility_value", units: 1)
			}
			let element = try pinnedElement(window)
			if bool(element, kAXMinimizedAttribute) == false {
				guard pinned(window) else { throw ServiceError.commandFailed("Window \(window.id) changed identity before restore completion") }
				return Outcome.noChange
			}
			guard AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
				throw ServiceError.interactionFailed("restore window", "Window restore operation failed")
			}
			let deadline = Date().addingTimeInterval(2)
			while Date() < deadline {
				let frame = AX.point(AX.value(element, kAXPositionAttribute)).map { CGRect(origin: $0, size: AX.size(AX.value(element, kAXSizeAttribute)) ?? .zero) }
				guard ownerGeneration(window), AX.windowID(element) == window.id, frame == window.bounds else {
					throw ManageFailure.unverified(action: "restore window", "accessibility_value", units: 1,
					                               cause: .commandFailed("Window \(window.id) changed identity during restore"))
				}
				if bool(element, kAXMinimizedAttribute) == false, pinned(window) { return Outcome.change("accessibility_value", units: 1) }
				pause(0.05)
			}
			throw ManageFailure.noop(action: "restore window", "accessibility_value", units: 1)
		}
	}

	/// Closes the exact window with AXClose, or its close button when it offers no AXClose, and waits until it
	/// stays gone. Peekaboo waits at least 4 s for a 2 s disappearance; a closed window doesn't come back with the
	/// same number, so a shorter wait proves the same.
	public static func closeWindow(_ window: ExactWindow) throws(ManageFailure) -> JSON {
		try perform("close window") {
			try validateMutation(window)
			guard Mac.window(window.id) != nil || window.isMinimized else { throw ServiceError.windowNotFound("windowId \(window.id)") }
			if window.isMinimized {
				throw ManageFailure.refused("foreground_consent_required", "A minimized window cannot be closed with a verified background-only route",
				                            hint: "Restore the same exact window first, or retry with explicit foreground consent.")
			}
			try dispatchClose(window)
			let verified: Bool
			do throws(ServiceError) { verified = try verifyClosed(window) } catch {
				throw ManageFailure.unverified(action: "close window", "accessibility_action", units: 1, cause: error)
			}
			// An accepted close may be waiting on unsaved work; it isn't safe to repeat.
			return verified ? Outcome.change("accessibility_action", units: 1)
				: Outcome.unverified("accessibility_action", evidence: "operation_still_running", units: 1)
		}
	}

	private static func dispatchClose(_ window: ExactWindow) throws(ManageFailure) {
		guard pinned(window), let element = axWindow(pid: window.pid, id: window.id) else {
			throw .refused("target_unavailable", "The exact window could not be verified before close.")
		}
		var names: CFArray?
		guard AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String] else {
			throw .refused("operation_unsupported", "The exact window's supported close actions could not be read.")
		}
		let receiver: AXUIElement
		let action: String
		if actions.contains("AXClose") {
			receiver = element
			action = "AXClose"
		} else {
			guard let button = AX.element(AX.value(element, kAXCloseButtonAttribute)) else {
				throw .refused("operation_unsupported", "The exact window exposes no supported background close route.")
			}
			AXUIElementSetMessagingTimeout(button, messagingTimeout)
			guard Mac.actions(button).contains(kAXPressAction) else {
				throw .refused("operation_unsupported", "The exact window's close button could not be verified.")
			}
			receiver = button
			action = kAXPressAction
		}
		guard AX.pid(receiver) == window.pid, AX.windowID(element) == window.id, AX.frame(element) == window.bounds,
		      bool(element, kAXMinimizedAttribute) == false, pinned(window)
		else { throw .refused("target_unavailable", "The exact window changed before close.") }
		let result = AXUIElementPerformAction(receiver, action as CFString)
		guard result == .success else {
			if result == .cannotComplete {
				throw ManageFailure(Outcome.indeterminate("accessibility_action", units: 1),
				                    "The close request may have been delivered; native completion is unknown.",
				                    hint: "Refresh the window inventory; do not blindly retry close.")
			}
			throw .refused("operation_unsupported", "Failed to perform close window: AX error \(result.rawValue)",
			               hint: "Use a window and host that support close window.")
		}
	}

	/// Whether the window stayed gone, from WindowServer and, when it disagrees with the receipt, Accessibility.
	private static func verifyClosed(_ window: ExactWindow) throws(ServiceError) -> Bool {
		let started = Date()
		var missingSince: TimeInterval?
		var presentSince: TimeInterval?
		while Date().timeIntervalSince(started) < 4.2 {
			let elapsed = Date().timeIntervalSince(started)
			let entry = Mac.window(window.id)
			if let entry, entry.pid != window.pid || startIdentity(entry.pid).value != window.generation {
				throw .commandFailed("Window \(window.id) changed owner identity during close")
			}
			var present: Bool
			if let entry, entry.bounds == window.bounds {
				present = true
			} else {
				switch axPresence(window) {
				case .present: present = true
				case .missing: present = false
				case .replacement: throw .commandFailed("Window \(window.id) changed identity during close")
				case .unverifiable: present = entry != nil
				}
			}
			if present {
				missingSince = nil
				presentSince = presentSince ?? elapsed
				if elapsed - presentSince! >= 0.75 { return false }
			} else {
				presentSince = nil
				missingSince = missingSince ?? elapsed
				if elapsed >= 0.6, elapsed - missingSince! >= 0.4 { return true }
			}
			pause(0.1)
		}
		return false
	}

	private enum Presence { case present, missing, replacement, unverifiable }

	private static func axPresence(_ window: ExactWindow) -> Presence {
		guard ownerGeneration(window) else { return .replacement }
		let app = AXUIElementCreateApplication(window.pid)
		AXUIElementSetMessagingTimeout(app, messagingTimeout)
		guard let list = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] else { return .unverifiable }
		var matching: [CGRect?] = []
		var complete = true
		for element in list {
			AXUIElementSetMessagingTimeout(element, messagingTimeout)
			guard let id = AX.windowID(element) else {
				complete = false
				continue
			}
			guard id == window.id else { continue }
			let frame = AX.frame(element)
			matching.append(frame)
			complete = complete && frame != nil
		}
		guard startIdentity(window.pid).value == window.generation else { return .replacement }
		if matching.contains(where: { $0 == window.bounds }) { return .present }
		if matching.contains(where: { $0 != nil }) { return .replacement }
		if !matching.isEmpty { return .unverifiable }
		return complete ? .missing : .unverifiable
	}

	/// Enters or leaves native full screen, setting AXFullScreen when it's settable and otherwise pressing the
	/// green button, which toggles, so only when the state differs.
	public static func setFullScreen(_ window: ExactWindow, _ enabled: Bool) throws(ManageFailure) -> JSON {
		let action = enabled ? "enter full screen" : "exit full screen"
		return try perform(action) {
			try validateMutation(window)
			guard !window.isMinimized else { throw ServiceError.invalidInput("Restore the minimized window before changing full screen") }
			let element = try pinnedElement(window)
			guard let current = bool(element, "AXFullScreen") else {
				throw ServiceError.interactionFailed(action, "The window does not report AXFullScreen, so it does not support native full screen")
			}
			if current == enabled { return Outcome.noChange }
			let mechanism: String
			if Mac.settable(element, "AXFullScreen") {
				mechanism = "accessibility_value"
				guard AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, enabled as CFBoolean) == .success else {
					throw ServiceError.interactionFailed(action, "Setting AXFullScreen failed")
				}
			} else if let button = AX.element(AX.value(element, "AXFullScreenButton")) {
				mechanism = "accessibility_action"
				guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
					throw ServiceError.interactionFailed(action, "Pressing the window's full screen button failed")
				}
			} else {
				throw ServiceError.interactionFailed(action, "The window exposes neither a settable AXFullScreen nor a full screen button")
			}
			// The transition animates for most of a second and moves the window, so only its number and owner pin it.
			let deadline = Date().addingTimeInterval(4)
			while Date() < deadline {
				guard ownerGeneration(window), AX.windowID(element) == window.id else {
					throw ManageFailure.unverified(action: action, mechanism, units: 1,
					                               cause: .commandFailed("Window \(window.id) changed owner/process generation during full screen"))
				}
				if bool(element, "AXFullScreen") == enabled { return Outcome.change(mechanism, units: 1) }
				pause(0.1)
			}
			throw ManageFailure.noop(action: action, mechanism, units: 1)
		}
	}

	/// The window's one Space and its kind: a full-screen window gets its own Space.
	public static func windowSpace(_ id: Int) -> (id: UInt64, kind: String)? {
		let ids = spaceIDs(window: id)
		guard ids.count == 1, let space = ids.first else { return nil }
		let raw = manageCopyManagedDisplaySpaces(manageDefaultConnection()) as? [[String: Any]] ?? []
		for display in raw {
			for entry in display["Spaces"] as? [[String: Any]] ?? [] where (entry["ManagedSpaceID"] as? NSNumber)?.uint64Value == space {
				let kind = switch (entry["type"] as? NSNumber)?.intValue {
				case 0: "desktop"
				case 4: "fullscreen"
				default: "other"
				}
				return (space, kind)
			}
		}
		return (space, "other")
	}

	// MARK: Focus

	/// Brings the exact window forward: activates its app when it isn't active, makes the window main and
	/// raises it, then waits until the app is frontmost with that window focused. Ported from Peekaboo's
	/// FocusManagementService.focusWindowWithOwnedLane with one attempt, as the native client asks.
	public static func focusWindow(_ window: ExactWindow) throws(ManageFailure) -> JSON {
		var units: [String] = []
		func outcome() -> JSON? {
			guard let first = units.first else { return nil }
			return Outcome.change(units.allSatisfy { $0 == first } ? first : "composite", mode: "foreground", units: units.count)
		}
		do {
			try validateMutation(window)
			guard Mac.window(window.id) != nil else { throw FocusFailure("Window with ID \(window.id) not found") }
			guard let element = axWindow(pid: window.pid, id: window.id), AX.windowID(element) == window.id, ownerGeneration(window)
			else { throw FocusFailure("Could not find accessibility element for window ID \(window.id)") }
			let pid = window.pid
			guard let app = NSRunningApplication(processIdentifier: pid) else { throw ServiceError.commandFailed("Window \(window.id) disappeared or changed identity") }
			let name = app.localizedName ?? "The application"
			var requested = false
			if !onMain({ NSRunningApplication(processIdentifier: pid)?.isActive == true }) {
				requested = onMain { NSRunningApplication(processIdentifier: pid)?.activate() == true }
				if requested { units.append("native_framework") }
			}
			var frontmost = false
			for _ in 0..<30 {
				if onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) {
					frontmost = true
					break
				}
				pause(0.1)
			}
			guard frontmost else {
				throw FocusFailure((requested
						? "\(name) (pid \(pid)) did not become the active app within 3 seconds of the activation request, so its window was not raised. macOS can decline activation requested from the background."
						: "\(name) (pid \(pid)) is not the active app and macOS did not accept the activation request, so its window was not raised.")
					+ " Activate the app, then retry; if it still isn't frontmost, ask the user to click the window.")
			}
			guard ownerGeneration(window), AX.windowID(element) == window.id else {
				throw FocusFailure("Could not find accessibility element for window ID \(window.id)")
			}
			if AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue) == .success {
				units.append("accessibility_value")
			}
			let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
			if raised == .success || ![.actionUnsupported, .attributeUnsupported].contains(raised) { units.append("accessibility_action") }
			let deadline = Date().addingTimeInterval(5)
			let appElement = AXUIElementCreateApplication(pid)
			AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
			while Date() < deadline {
				let focused = AX.element(AX.value(appElement, kAXFocusedWindowAttribute)).flatMap(AX.windowID)
				if focused == window.id, onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) {
					return outcome() ?? Outcome.noChange
				}
				pause(0.1)
			}
			throw FocusFailure("Timeout while verifying focus for window ID \(window.id)")
		} catch let error as FocusFailure {
			throw focusFailure(error.message, cause: error.message, units: units)
		} catch let error as ServiceError {
			throw focusFailure(error.message, cause: error.cause, units: units, reason: error.reason)
		} catch {
			throw focusFailure(String(describing: error), cause: nil, units: units)
		}
	}

	private struct FocusFailure: Error {
		let message: String
		init(_ message: String) { self.message = message }
	}

	private static func focusFailure(_ message: String, cause: String?, units: [String], reason: String = "operation_unsupported") -> ManageFailure {
		guard let first = units.first else {
			let hint = reason == "target_unavailable" ? "Refresh the exact window receipt before retrying." : "Use a window and host that support focus window."
			return .refused(reason, message, hint: hint, cause: cause)
		}
		return ManageFailure(Outcome.unverified(units.allSatisfy { $0 == first } ? first : "composite", mode: "foreground",
		                                        evidence: "delivery_accepted", units: units.count),
		                     "Window focus did not complete with a verified exact target.",
		                     hint: "Observe the exact window before retrying focus.", cause: cause)
	}

	// MARK: Applications

	/// WindowServer's view of activation: whether the app has a visible normal window, and whose is frontmost.
	private static func activationState(_ pid: pid_t) -> (hasWindow: Bool, frontmost: pid_t?) {
		let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
		var frontmost: pid_t?
		var hasWindow = false
		for info in list {
			guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
			      (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
			      ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
			else { continue }
			if frontmost == nil { frontmost = owner }
			if owner == pid { hasWindow = true }
		}
		return (hasWindow, frontmost)
	}

	private static func verifiedActive(_ pid: pid_t) -> Bool {
		let (active, front) = onMain { (NSRunningApplication(processIdentifier: pid)?.isActive == true, NSWorkspace.shared.frontmostApplication?.processIdentifier) }
		guard active, front == pid else { return false }
		let state = activationState(pid)
		return !state.hasWindow || state.frontmost == pid
	}

	/// Activates the app until it's active, frontmost and owns the frontmost window, within 2 s, falling back to
	/// Accessibility's AXFrontmost after the first try. Ported from Peekaboo's requestVerifiedActivation.
	public static func activate(pid: pid_t, generation: UInt64) throws(ManageFailure) -> JSON {
		guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, startIdentity(pid).value == generation else {
			throw .refused("target_unavailable", "Failed to activate application: target process generation changed before dispatch",
			               hint: "Refresh the exact window receipt before retrying.")
		}
		let name = app.localizedName ?? "Unknown"
		let deadline = Date().addingTimeInterval(2)
		var mechanisms: [String] = []
		var fallback = false
		while true {
			if verifiedActive(pid) { break }
			let accepted = onMain { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) == true }
			if accepted { mechanisms.append("native_framework") }
			if fallback || !accepted {
				let element = AXUIElementCreateApplication(pid)
				if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success {
					mechanisms.append("accessibility_action")
				}
			}
			if verifiedActive(pid) { break }
			guard Date() < deadline else {
				let front = onMain { NSWorkspace.shared.frontmostApplication.map { "\($0.localizedName ?? "unknown") (PID: \($0.processIdentifier))" } } ?? "none"
				let window = activationState(pid).frontmost.map(String.init) ?? "none"
				let diagnostic = "Activation verification failed for \(name) (native accepted: \(mechanisms.contains("native_framework")), AX accepted: \(mechanisms.contains("accessibility_action")), frontmost: \(front), frontmost window PID: \(window))"
				guard let last = mechanisms.last else {
					throw .refused("target_unavailable", "The activation request was not accepted for \(name).",
					               hint: "Refresh the application inventory before retrying.", cause: diagnostic)
				}
				let mixed = Set(mechanisms).count > 1
				throw ManageFailure(Outcome.noop(last, mode: "foreground", units: mixed ? nil : mechanisms.count),
				                    "Application did not become active and frontmost: \(name).",
				                    hint: "Refresh the frontmost application and window inventory before retrying.", cause: diagnostic)
			}
			pause(min(0.1, max(0, deadline.timeIntervalSinceNow)))
			fallback = true
		}
		guard startIdentity(pid).value == generation else {
			throw ManageFailure(Outcome.unverified(mechanisms.last ?? "native_framework", mode: "foreground", evidence: "operation_still_running", units: mechanisms.count),
			                    "Activate application was dispatched, but completion could not be confirmed.",
			                    hint: "Observe the target state before retrying.",
			                    cause: ServiceError.commandFailed("The activation target changed process generation before verification completed").cause)
		}
		guard let last = mechanisms.last else { return Outcome.noChange }
		return Outcome.change(last, mode: "foreground", units: Set(mechanisms).count > 1 ? nil : mechanisms.count)
	}

	/// Hides the app with Accessibility's AXHide when it offers one, else AppKit, and waits up to 1 s for it.
	/// Ported from Peekaboo's performApplicationVisibilityMutation.
	public static func hide(pid: pid_t, generation: UInt64) throws(ManageFailure) -> JSON {
		guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, startIdentity(pid).value == generation else {
			throw .refused("target_unavailable", "Application PID \(pid) disappeared or changed process generation before visibility dispatch.",
			               hint: "Refresh the application inventory before retrying.",
			               cause: ServiceError.commandFailed("Application PID \(pid) disappeared or changed process generation").cause)
		}
		func hidden() -> Bool { onMain { NSRunningApplication(processIdentifier: pid)?.isHidden == true } }
		if hidden() { return Outcome.noChange }
		let element = AXUIElementCreateApplication(pid)
		AXUIElementSetMessagingTimeout(element, messagingTimeout)
		let mechanism: String
		if Mac.actions(element).contains("AXHide") {
			let result = AXUIElementPerformAction(element, "AXHide" as CFString)
			if result == .success {
				mechanism = "accessibility_action"
			} else if [.actionUnsupported, .apiDisabled].contains(result) {
				submitHide(pid)
				mechanism = "native_framework"
			} else {
				throw ManageFailure(Outcome.indeterminate("accessibility_action", units: 1),
				                    "Hide application may have been dispatched, but completion is unknown.",
				                    hint: "Observe the target state before retrying.", cause: "AX error \(result.rawValue)")
			}
		} else {
			submitHide(pid)
			mechanism = "native_framework"
		}
		let deadline = Date().addingTimeInterval(1)
		repeat {
			guard startIdentity(pid).value == generation else {
				throw ManageFailure(Outcome.unverified(mechanism, evidence: "delivery_accepted", units: 1),
				                    "Hide application was dispatched, but completion could not be confirmed.",
				                    hint: "Observe the target state before retrying.",
				                    cause: ServiceError.commandFailed("Hide application target changed process generation before its result observation").cause)
			}
			if hidden() { return Outcome.change(mechanism, units: 1) }
			pause(0.05)
		} while Date() < deadline
		throw ManageFailure(Outcome.noop(mechanism, units: 1), "Hide application was accepted, but the requested visibility did not change.",
		                    hint: "Refresh the application inventory before retrying.")
	}

	/// NSRunningApplication.hide can return false although the request takes effect, so the hidden state polled
	/// after it decides the outcome, as in Peekaboo's submitNativeApplicationVisibility.
	private static func submitHide(_ pid: pid_t) {
		onMain { _ = NSRunningApplication(processIdentifier: pid)?.hide() }
	}

	/// Asks the app to quit, or force quits it, and waits up to 3 s for it to end. Ported from Peekaboo's
	/// quitApplicationActionResult.
	public static func quit(pid: pid_t, generation: UInt64, force: Bool) throws(ManageFailure) -> (outcome: JSON, terminated: Bool) {
		guard let app = NSRunningApplication(processIdentifier: pid), startIdentity(pid).value == generation else {
			throw .refused("target_unavailable", "Command failed: Application PID \(pid) disappeared or changed process generation",
			               hint: "Refresh the exact window receipt before retrying.")
		}
		let accepted = onMain { force ? app.forceTerminate() : app.terminate() }
		guard accepted else {
			throw .refused("target_unavailable", "The quit request was not accepted for \(app.localizedName ?? "Unknown").",
			               hint: "Refresh the application inventory before retrying.")
		}
		func gone() -> Bool { app.isTerminated || NSRunningApplication(processIdentifier: pid) == nil }
		var terminated = gone()
		let deadline = Date().addingTimeInterval(3)
		while !terminated, Date() < deadline {
			pause(0.1)
			terminated = gone()
		}
		if terminated { return (Outcome.change("native_framework", units: 1), true) }
		// An accepted quit can be waiting on unsaved work; repeating it isn't safe.
		return (force ? Outcome.noop("native_framework", units: 1)
			: Outcome.unverified("native_framework", evidence: "operation_still_running", units: 1), false)
	}

	// MARK: Launch and open

	public struct Launched: Sendable {
		public let pid: pid_t
		public let generation: UInt64
		public let name: String
		public let bundleID: String?
		public let path: String?
		public let outcome: JSON
	}

	/// Every window number WindowServer knows, taken just before an opening request.
	public static func windowNumbers() -> Set<Int> {
		let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
		return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
	}

	/// Opens the app, or items in it or their default handler, then waits until it has finished launching. In
	/// the background unless `activate`, so the user keeps typing where they are (#162); with `activate`, it also
	/// waits until the app is active. Ported from Peekaboo's performApplicationLaunchWithOutcomeOwnedLane.
	public static func launch(path: String?, bundleID: String?, urls: [URL], activate: Bool) async throws(ManageFailure) -> Launched {
		let mode = activate ? "foreground" : "background"
		let hint = "Verify the application selector or launch options before choosing a new action."
		var applicationURL: URL?
		if let bundleID {
			guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
				throw .refused("target_unavailable", "Application '\(bundleID)' not found", hint: hint)
			}
			applicationURL = url
		} else if let path {
			let expanded = NSString(string: path).expandingTildeInPath
			guard FileManager.default.fileExists(atPath: expanded) else {
				throw .refused("target_unavailable", "Application '\(path)' not found", hint: hint)
			}
			applicationURL = URL(fileURLWithPath: expanded)
		}
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = activate
		if path != nil { configuration.allowsRunningApplicationSubstitution = false }
		let opened: NSRunningApplication
		do {
			opened = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
				let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { app, error in
					if let app { continuation.resume(returning: app) } else {
						continuation.resume(throwing: error ?? ServiceError.commandFailed("LaunchServices returned no application"))
					}
				}
				if let applicationURL {
					if urls.isEmpty {
						NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration, completionHandler: done)
					} else {
						NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration, completionHandler: done)
					}
				} else {
					NSWorkspace.shared.open(urls[0], configuration: configuration, completionHandler: done)
				}
			}
		} catch {
			throw ManageFailure(Outcome.indeterminate("native_framework", mode: mode, units: 1),
			                    "Launch application may have been dispatched, but completion is unknown.",
			                    hint: "Observe the target state before retrying.", cause: String(describing: error))
		}
		let pid = opened.processIdentifier
		var units = 1
		do throws(ServiceError) {
			guard let generation = startIdentity(pid).value else { throw .commandFailed("Application changed process generation during launch readiness") }
			func check() throws(ServiceError) {
				guard opened.processIdentifier == pid, !opened.isTerminated, startIdentity(pid).value == generation else {
					throw .commandFailed("Application changed process generation during launch readiness")
				}
			}
			if activate, !(await MainActor.run { opened.isActive }) {
				if await MainActor.run(body: { opened.activate(options: [.activateAllWindows]) }) { units += 1 }
			}
			let ready = Date().addingTimeInterval(10)
			while !(await MainActor.run { opened.isFinishedLaunching }) {
				try check()
				guard !opened.isTerminated else { throw .commandFailed("Application terminated before it finished launching") }
				guard Date() < ready else { throw .timeout("Application did not become ready within 10.0 seconds") }
				try? await Task.sleep(for: .milliseconds(100))
			}
			try check()
			if activate {
				let active = Date().addingTimeInterval(2)
				while !(await MainActor.run { opened.isActive }), Date() < active {
					if await MainActor.run(body: { opened.activate(options: [.activateAllWindows]) }) { units += 1 }
					try? await Task.sleep(for: .milliseconds(50))
				}
				guard await MainActor.run(body: { opened.isActive }) else {
					throw .timeout("Application did not become active within 2 seconds: \(opened.localizedName ?? "unknown")")
				}
				try check()
			}
			// An explicit path is reported in one canonical spelling.
			let bundlePath = path != nil ? applicationURL.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } : opened.bundleURL?.path
			// LaunchServices accepting a document or URL doesn't establish its effect.
			let outcome = urls.isEmpty ? Outcome.change("native_framework", mode: mode, units: units)
				: Outcome.unverified("native_framework", mode: mode, evidence: "delivery_accepted", units: units)
			return Launched(pid: pid, generation: generation, name: opened.localizedName ?? "Unknown", bundleID: opened.bundleIdentifier,
			                path: bundlePath, outcome: outcome)
		} catch {
			throw ManageFailure(Outcome.unverified("native_framework", mode: mode, evidence: "operation_still_running", units: units),
			                    "Launch application was dispatched, but completion could not be confirmed.",
			                    hint: "Observe the target state before retrying.", cause: error.cause)
		}
	}

	/// Waits up to `seconds` for a new normal window of the process, letting several settle, never sending input.
	public static func awaitNewWindow(pid: pid_t, before: Set<Int>, seconds: Double) async {
		let deadline = Date().addingTimeInterval(seconds)
		repeat {
			let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
			let appeared = list.contains { info in
				(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
					&& (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
					&& !before.contains((info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)
			}
			if appeared {
				try? await Task.sleep(for: .milliseconds(250))
				return
			}
			try? await Task.sleep(for: .milliseconds(125))
		} while Date() < deadline
	}
}
