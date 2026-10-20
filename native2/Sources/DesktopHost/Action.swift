import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

extension Tools {
	/// One input action on a snapshot, with the checks, refusal shapes and follow-up observation every action
	/// shares, as the native client and the Node server give them. `deliver` runs on its own thread after the
	/// snapshot is spent; a Refusal it throws sends nothing and returns the snapshot. Without `observe`, the result is
	/// the native client's own action, as composed tools such as notifications read it: no availability, no observation.
	static func act(
		_ name: String, snapshotID: String, element id: String?, allowsDisabled: Bool = false, early: Refusal? = nil, observe: Bool = true,
		precheck: (Snapshot, Element?) throws -> Void = { _, _ in },
		deliver: @escaping @Sendable (Snapshot, Element?) throws -> Delivery
	) async -> ToolResult {
		var action: [(String, JSON)] = [("outcome", "refused"), ("action", JSON(name)), ("snapshot_id", JSON(snapshotID))]
		var receipt: JSON?
		func refused(_ code: String, _ message: String, hint: String? = nil, cause: String? = nil, fresh: Bool, native: JSON? = nil) async -> ToolResult {
			var error: [(String, JSON)] = [("code", JSON(code)), ("message", JSON(message))]
			if let hint { error.append(("hint", JSON(hint))) }
			if let cause { error.append(("cause", JSON(cause))) }
			action += [("requires_fresh_observation", JSON(fresh)), ("error", .object(error))]
			if let native { action.append(("native_outcome", native)) }
			if let receipt { action.append(("target_receipt", receipt)) }
			// A refusal from a window that is no longer available says why, as the Node server's explainRefusal does.
			if observe, let receipt, let pid = receipt["pid"]?.int.flatMap(Int32.init(exactly:)), let window = receipt["window_id"]?.int {
				let availability = await targetAvailability(pid: pid, windowID: window, message: message)
				if availability["availability"]?["state"]?.string != "available" {
					action.append(("target_availability", availability["availability"] ?? .null))
				}
			}
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: "refused", isError: true)
		}

		// The native client refuses some requests before it looks the snapshot up.
		if let early { return await refused(early.code, early.message, hint: early.hint, cause: early.cause, fresh: false) }
		guard let observed = await Snapshots.shared.get(snapshotID) else {
			// The native client asks the host whether it owns a well-formed reference, and refuses any other first.
			let wellFormed = snapshotID.utf8.count == 36 && snapshotID.hasPrefix("ps1_")
				&& snapshotID.utf8.dropFirst(4).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
			return wellFormed
				? await refused("DESKTOP_ACTION_FAILED", "This observation no longer belongs to the running desktop. Inspect the window again.", fresh: true)
				: await refused("invalidRequest", "Invalid producer-bound snapshot reference", fresh: true)
		}
		receipt = .object([
			("pid", JSON(observed.pid)), ("window_id", JSON(observed.windowID)),
			("process_start_identity_decimal", JSON(String(observed.generation))),
		])
		var target: Element?
		if let id {
			guard let found = observed.elements[id] else {
				return await refused("invalidRequest", "The element ID is not in this snapshot. Inspect the window again.", fresh: false)
			}
			guard allowsDisabled || found.isEnabled || found.attributes["axEnabledKnown"] != "true" else {
				return await refused("invalidRequest", "The observed element is disabled.", fresh: false)
			}
			target = found
		}
		do { try precheck(observed, target) } catch let refusal as Refusal {
			return await refused(refusal.code, refusal.message, hint: refusal.hint, cause: refusal.cause, fresh: false)
		} catch {
			return await refused("invalidRequest", (error as? ToolError)?.message ?? String(describing: error), fresh: false)
		}
		let snapshot: Snapshot
		do { snapshot = try await Snapshots.shared.spend(snapshotID) } catch let error as ToolError {
			return await refused("invalidRequest", String(error.message.dropFirst("invalidRequest: ".count)), fresh: true)
		} catch {
			return await refused("invalidRequest", String(describing: error), fresh: true)
		}
		let delivery: Delivery
		do {
			let chosen = target
			delivery = try await run { try deliver(snapshot, chosen) }
		} catch let refusal as Refusal {
			await Snapshots.shared.release(snapshotID)
			action += refusal.fields
			return await refused(refusal.code, refusal.message, hint: refusal.hint, cause: refusal.cause, fresh: false, native: refusal.fromHost ? refusal.outcome : nil)
		} catch {
			// Anything else may have happened mid-delivery.
			action[0] = ("outcome", "unknown")
			action += [("requires_fresh_observation", true), ("error", .object([("code", "DESKTOP_ACTION_FAILED"), ("message", JSON(String(describing: error)))])), ("target_receipt", receipt!)]
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: "unknown", isError: true)
		}
		let dispatched = delivery.state != .confirmedNoChange
		if !dispatched { await Snapshots.shared.release(snapshotID) }
		action[0] = ("outcome", JSON(delivery.outcome))
		action += delivery.fields
		action += [("native_outcome", delivery.json), ("requires_fresh_observation", JSON(dispatched)), ("target_receipt", receipt!)]
		guard delivery.outcome == "completed", observe else {
			return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: delivery.outcome, isError: delivery.outcome != "completed")
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

	/// The window a snapshot observed, which input must still find unchanged.
	static func window(_ snapshot: Snapshot) -> ClickWindow {
		ClickWindow(pid: snapshot.pid, generation: snapshot.generation, windowID: snapshot.windowID, bounds: snapshot.windowBounds)
	}

	/// A fraction of the screenshot as a global point: the screenshot is the whole window.
	static func globalPoint(_ fraction: CGPoint, in bounds: CGRect) -> CGPoint {
		CGPoint(x: bounds.minX + fraction.x * bounds.width, y: bounds.minY + fraction.y * bounds.height)
	}

	/// A normalized screenshot point from the arguments.
	static func fraction(_ value: JSON?) throws -> CGPoint? {
		guard let value else { return nil }
		guard let keys = value.keys, keys.contains("x"), keys.contains("y") else {
			throw ToolError("Choose a normalized screenshot point with x and y coordinates.")
		}
		guard let x = value["x"]?.number, let y = value["y"]?.number, [x, y].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1 }) else {
			throw ToolError("Screenshot point coordinates must be at least 0 and less than 1.")
		}
		return CGPoint(x: x, y: y)
	}

	static func snapshotArgument(_ arguments: JSON) throws -> String {
		guard let id = arguments["snapshot"]?.string, (1...256).contains(id.count) else {
			throw ToolError("Use the snapshot_id from a fresh desktop_inspect result.")
		}
		return id
	}
}
