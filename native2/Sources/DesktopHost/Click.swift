import ApplicationServices
import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

extension Tools {
	static func click(_ arguments: JSON) async throws -> ToolResult {
		guard let snapshotID = arguments["snapshot"]?.string, (1...256).contains(snapshotID.count) else {
			throw ToolError("Use the snapshot_id from a fresh desktop_inspect result.")
		}
		let element = arguments["element"]
		let point = arguments["point"]
		guard (element == nil) != (point == nil) else {
			throw ToolError("Choose exactly one observed element ID or normalized screenshot point.")
		}
		var fraction: CGPoint?
		if let point {
			guard let x = point["x"]?.number, let y = point["y"]?.number else {
				throw ToolError("Choose a normalized screenshot point with x and y coordinates.")
			}
			guard [x, y].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1 }) else {
				throw ToolError("Screenshot point coordinates must be at least 0 and less than 1.")
			}
			fraction = CGPoint(x: x, y: y)
		} else if element?.string.map({ (1...256).contains($0.count) }) != true {
			throw ToolError("Choose an element ID from the inspected snapshot.")
		}
		guard let kind = ClickKind(rawValue: arguments["kind"]?.string ?? "single") else {
			throw ToolError("Choose single, double, right, middle, or triple click.")
		}
		for unsupported in ["modifiers", "expect"] where arguments[unsupported] != nil {
			throw ToolError("desktop_click's \(unsupported) isn't in the Swift spike yet.")
		}

		var action: [(String, JSON)] = [("outcome", "refused"), ("action", "click"), ("snapshot_id", JSON(snapshotID))]
		var receipt: JSON?
		func refused(_ code: String, _ message: String, fresh: Bool, native: JSON? = nil) async -> ToolResult {
			action += [("requires_fresh_observation", JSON(fresh)), ("error", .object([("code", JSON(code)), ("message", JSON(message))]))]
			if let native { action.append(("native_outcome", native)) }
			if let receipt { action.append(("target_receipt", receipt)) }
			var data: JSON = .object([("action", .object(action))])
			// A refusal from a window that is no longer available says why, as the Node server's explainRefusal does.
			if let receipt, let pid = receipt["pid"]?.int.flatMap(Int32.init(exactly:)), let window = receipt["window_id"]?.int {
				let availability = await targetAvailability(pid: pid, windowID: window, message: message)
				if availability["availability"]?["state"]?.string != "available" {
					action.append(("target_availability", availability["availability"] ?? .null))
					data = .object([("action", .object(action))])
				}
			}
			return ToolResult(text: data.text, outcome: "refused", isError: true)
		}

		guard let observed = await Snapshots.shared.get(snapshotID) else {
			return await refused("invalidRequest", "Snapshot '\(snapshotID)' is unknown or expired. Inspect the window again.", fresh: false)
		}
		receipt = .object([
			("pid", JSON(observed.pid)), ("window_id", JSON(observed.windowID)),
			("process_start_identity_decimal", JSON(String(observed.generation))),
		])
		var target: Element?
		if let id = element?.string {
			guard let found = observed.elements[id] else {
				return await refused("invalidRequest", "The element ID is not in this snapshot. Inspect the window again.", fresh: false)
			}
			guard found.isEnabled || found.attributes["axEnabledKnown"] != "true" else {
				return await refused("invalidRequest", "The observed element is disabled.", fresh: false)
			}
			target = found
		}
		let snapshot: Snapshot
		do { snapshot = try await Snapshots.shared.spend(snapshotID) } catch let error as ToolError {
			return await refused("invalidRequest", String(error.message.dropFirst("invalidRequest: ".count)), fresh: true)
		}
		let window = ClickWindow(pid: snapshot.pid, generation: snapshot.generation, windowID: snapshot.windowID, bounds: snapshot.windowBounds)
		// The screenshot is the whole window, so a fraction of it is the same fraction of the window's bounds.
		let global = fraction.map { CGPoint(x: window.bounds.minX + $0.x * window.bounds.width, y: window.bounds.minY + $0.y * window.bounds.height) }
			?? CGPoint(x: target!.frame.midX, y: target!.frame.midY)

		let delivery: Delivery
		do {
			let reference = target.map { UncheckedReference($0.reference) }
			delivery = try await run {
				try window.check()
				switch (kind, reference) {
				case (.single, let element?):
					do { return try Mac.clickElement(element.value, window: window) } catch is Unsupported {
						return try Mac.clickPoint(global, window: window)
					}
				case (.single, nil):
					return try Mac.clickPoint(global, window: window)
				case (.right, let element?):
					do { return try Mac.showMenu(element.value, window: window) } catch is Unsupported {
						return try Mac.routedClick(at: global, kind: kind, window: window)
					}
				default:
					return try Mac.routedClick(at: global, kind: kind, window: window)
				}
			}
		} catch let refusal as Refusal {
			await Snapshots.shared.release(snapshotID)
			return await refused(refusal.code, refusal.message, fresh: false, native: Refusal.outcome)
		}
		let dispatched = delivery.state != .confirmedNoChange
		if !dispatched { await Snapshots.shared.release(snapshotID) }
		action[0] = ("outcome", JSON(delivery.outcome))
		action += [("native_outcome", delivery.json), ("requires_fresh_observation", JSON(dispatched)), ("target_receipt", receipt!)]
		guard delivery.outcome == "completed" else {
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: delivery.outcome, isError: true)
		}
		// Observation is separate from delivery: its failure must not turn completed input into a retry.
		do {
			var (fresh, image) = try await observation(pid: snapshot.pid, windowID: snapshot.windowID)
			fresh.set("action", .object(action))
			return ToolResult(text: try boundedObservation(fresh), outcome: "completed", image: image)
		} catch {
			action += [
				("observation_error", JSON((error as? ToolError)?.message ?? String(describing: error))),
				("message", "The action completed, but a fresh observation was unavailable. Inspect again to verify the result; do not repeat the action blindly."),
			]
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: "completed")
		}
	}
}

/// An Accessibility reference handed to the thread that acts on it.
private struct UncheckedReference: @unchecked Sendable {
	let value: AXUIElement
	init(_ value: AXUIElement) { self.value = value }
}
