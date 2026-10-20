import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

// desktop_press, desktop_click with modifiers and foreground desktop_drag, as the native client's action
// runner gives them (native/Sources/client/actions.swift) after Node's checks (src/client.ts validateAction).

extension Tools {
	static func press(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let (element, fraction) = try target(arguments)
		let button = arguments["button"]?.string ?? "left"
		guard ["left", "right"].contains(button), arguments["button"] == nil || arguments["button"]?.string != nil else {
			throw ToolError("Choose the left or right mouse button for a press.")
		}
		let duration = arguments["duration_ms"]?.int ?? 1000
		guard (1...10000).contains(duration), arguments["duration_ms"] == nil || arguments["duration_ms"]?.int != nil else {
			throw ToolError("Press duration must be 1 to 10000 milliseconds.")
		}
		let point = pointerPoint(fraction)
		return await act("press", snapshotID: snapshotID, element: element, precheck: { snapshot, target in
			try requireCenter(point(snapshot, target), snapshot)
		}) { snapshot, target in
			let window = window(snapshot)
			try window.check()
			let at = point(snapshot, target)
			Hooks.showPointer(.hold(at: at, window: snapshot.windowID))
			defer { Hooks.showPointer(.click(at: at, kind: .single, window: snapshot.windowID)) }
			return try Mac.press(at: at, button: button == "right" ? .right : .left, milliseconds: duration, window: window)
		}
	}

	/// A click holding modifiers, which only real pointer input carries: the host activates the app, clicks
	/// while holding the keys, then restores the pointer and the previously focused window.
	static func modifierClick(_ snapshotID: String, element: String?, fraction: CGPoint?, kind: ClickKind, modifiers: [String]) async -> ToolResult {
		let point = pointerPoint(fraction)
		return await act("click", snapshotID: snapshotID, element: element, precheck: { snapshot, target in
			try requireCenter(point(snapshot, target), snapshot)
		}) { snapshot, target in
			let window = window(snapshot)
			try window.check()
			let at = point(snapshot, target)
			Hooks.showPointer(.click(at: at, kind: kind, window: snapshot.windowID))
			return try Mac.modifierClick(at: at, kind: kind, modifiers: modifiers, window: window)
		}
	}

	/// The modifiers a click may hold, in Node's order of checks.
	static func clickModifiers(_ arguments: JSON, kind: ClickKind) throws -> [String]? {
		guard arguments["modifiers"] != nil else { return nil }
		let modifiers = try modifierList(arguments["modifiers"])
		if modifiers.isEmpty || modifiers.contains("control") {
			throw ToolError("Hold command, option or shift; a Control-click is kind right without modifiers.")
		}
		guard [.single, .double, .triple].contains(kind) else {
			throw ToolError("Modifier keys can be held only for single, double, or triple clicks.")
		}
		return modifiers
	}

	/// Hover, press and modifier clicks act on a point, so an element target resolves to its observed center.
	private static func pointerPoint(_ fraction: CGPoint?) -> @Sendable (Snapshot, Element?) -> CGPoint {
		{ snapshot, target in
			fraction.map { globalPoint($0, in: snapshot.windowBounds) } ?? CGPoint(x: target!.frame.midX, y: target!.frame.midY)
		}
	}

	private static func requireCenter(_ point: CGPoint, _ snapshot: Snapshot) throws {
		guard snapshot.windowBounds.contains(point) else {
			throw Refusal("DESKTOP_ACTION_FAILED", "The element's center is outside its exact captured window.", fromHost: false)
		}
	}

	// MARK: Foreground drag

	/// A drag into another window, or holding modifier keys, with the real pointer and keys. Nothing can confirm
	/// a drop, so a dispatched drag is unknown.
	static func foregroundDrag(
		_ snapshotID: String, to destinationID: String?, from: CGPoint, through waypoints: [CGPoint], to end: CGPoint,
		button: CGMouseButton, milliseconds: Int, modifiers: [String]
	) async -> ToolResult {
		var action: [(String, JSON)] = [("outcome", "refused"), ("action", "drag"), ("snapshot_id", JSON(snapshotID))]
		var receipt: JSON?
		func receiptOf(_ snapshot: Snapshot) -> JSON {
			.object([
				("pid", JSON(snapshot.pid)), ("window_id", JSON(snapshot.windowID)),
				("process_start_identity_decimal", JSON(String(snapshot.generation))),
			])
		}
		// Every foreground drag result asks for a fresh observation, refusals included.
		func refused(_ code: String, _ message: String) async -> ToolResult {
			action += [("requires_fresh_observation", true), ("error", .object([("code", JSON(code)), ("message", JSON(message))]))]
			if let receipt { action.append(("target_receipt", receipt)) }
			if let receipt, let pid = receipt["pid"]?.int.flatMap(Int32.init(exactly:)), let window = receipt["window_id"]?.int {
				let availability = await targetAvailability(pid: pid, windowID: window, message: message)
				if availability["availability"]?["state"]?.string != "available" {
					action.append(("target_availability", availability["availability"] ?? .null))
				}
			}
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: "refused", isError: true)
		}
		guard let source = await Snapshots.shared.get(snapshotID) else {
			return await refused("invalidRequest", "Invalid producer-bound snapshot reference")
		}
		receipt = receiptOf(source)
		guard let destination = await Snapshots.shared.get(destinationID ?? snapshotID) else {
			return await refused("invalidRequest", "Invalid producer-bound snapshot reference")
		}
		let across = destinationID != nil
		if across { action.append(("destination_receipt", receiptOf(destination))) }
		let start = globalPoint(from, in: source.windowBounds)
		let finish = globalPoint(end, in: destination.windowBounds)
		let path = waypoints.map { globalPoint($0, in: source.windowBounds) }
		guard Mac.exposes(start, window: window(source)) else {
			return await refused("DESKTOP_ACTION_FAILED", "Another window covers the start point, or its window moved since the snapshot. Inspect it again; bring it forward with desktop_focus if it is covered.")
		}
		guard Mac.exposes(finish, window: window(destination)) else {
			return await refused("DESKTOP_ACTION_FAILED", across
				? "Another window covers the end point, or its window moved since the snapshot. Arrange the windows so both points are visible, then inspect both again."
				: "Another window covers the end point, or the window moved since the snapshot. Inspect it again; bring it forward with desktop_focus if it is covered.")
		}
		guard path.allSatisfy({ Mac.exposes($0, window: window(source)) }) else {
			return await refused("DESKTOP_ACTION_FAILED", "Another window covers a point on the path, or the window moved since the snapshot. Inspect it again; bring it forward with desktop_focus if it is covered.")
		}
		do {
			_ = try await Snapshots.shared.spend(snapshotID)
			if let destinationID {
				do { _ = try await Snapshots.shared.spend(destinationID) } catch {
					await Snapshots.shared.release(snapshotID)
					throw error
				}
			}
		} catch {
			let message = (error as? ToolError)?.message ?? String(describing: error)
			return await refused("invalidRequest", message.hasPrefix("invalidRequest: ") ? String(message.dropFirst("invalidRequest: ".count)) : message)
		}
		Hooks.showPointer(.drag(from: start, to: finish, seconds: Double(milliseconds) / 1000, window: source.windowID))
		let delivery = (try? await run {
			Mac.foregroundDrag(from: start, through: path, to: finish, button: button, milliseconds: milliseconds, modifiers: modifiers)
		}) ?? Delivery(state: .indeterminate, mechanism: "global_events", evidence: "completion_unknown", units: 1)
		let moved = (CGEvent(source: nil)?.location).map { hypot($0.x - finish.x, $0.y - finish.y) <= 1 } ?? false
		let held = modifiers.isEmpty ? "" : ", holding \(modifiers.joined(separator: " and ")),"
		action[0] = ("outcome", "unknown")
		action += [
			("native_outcome", delivery.json), ("pointer_moved", JSON(moved)), ("requires_fresh_observation", true),
			("error", .object([
				("code", "DESKTOP_ACTION_UNVERIFIED"),
				("message", JSON(across
					? "The drag was sent as real pointer input\(held) which moved the pointer and may have activated the source app. A drop between windows can't be confirmed."
					: "The drag was sent as real pointer input\(held) which moved the pointer and may have activated the app. Its effect can't be confirmed.")),
				("hint", JSON(across
					? "Inspect both windows to see whether the drop happened. Never repeat the drag blindly."
					: "Inspect the window to see what the drag did. Never repeat the drag blindly.")),
			])),
			("target_receipt", receipt!),
		]
		return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: "unknown", isError: true)
	}
}
