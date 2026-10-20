import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

extension Tools {
	static func scroll(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let (element, fraction) = try target(arguments)
		guard let direction = arguments["direction"]?.string.flatMap(ScrollDirection.init(rawValue:)),
		      let amount = arguments["amount"]?.int, (1...20).contains(amount)
		else { throw ToolError("Choose up, down, left, or right and 1 to 20 native scroll units.") }
		return await act("scroll", snapshotID: snapshotID, element: element) { snapshot, target in
			let window = window(snapshot)
			try window.check()
			if let target { return try Mac.scroll(target.reference, direction: direction, amount: amount, window: window) }
			return try Mac.scroll(at: globalPoint(fraction!, in: window.bounds), direction: direction, amount: amount, window: window)
		}
	}

	static func drag(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		guard let from = try fraction(arguments["from"] ?? .null), let to = try fraction(arguments["to"] ?? .null) else {
			throw ToolError("Choose distinct start and end points for a drag.")
		}
		let toSnapshot = arguments["to_snapshot"]
		if let toSnapshot, toSnapshot.string.map({ (1...256).contains($0.count) && $0 != snapshotID }) != true {
			throw ToolError("Use another window's snapshot_id as to_snapshot, or omit it to drag within one window.")
		}
		var waypoints: [CGPoint] = []
		if let path = arguments["path"] {
			guard let list = path.array, (1...16).contains(list.count) else { throw ToolError("Give a drag path of 1 to 16 normalized screenshot points.") }
			if toSnapshot != nil { throw ToolError("A drag path stays in one window; omit path to drag into another window.") }
			waypoints = try list.map { try fraction($0)! }
		}
		guard from != to || !waypoints.isEmpty || toSnapshot != nil else { throw ToolError("Choose distinct start and end points for a drag.") }
		let modifiers = try modifierList(arguments["modifiers"])
		let button = arguments["button"]?.string ?? "left"
		guard ["left", "right"].contains(button), arguments["button"] == nil || arguments["button"]?.string != nil else {
			throw ToolError("Choose the left or right mouse button for a drag.")
		}
		// A foreground drag defaults to a slower 800 ms, which drops between windows need.
		let foreground = toSnapshot != nil || !modifiers.isEmpty
		let duration = arguments["duration_ms"]?.int ?? (foreground ? 800 : 500)
		guard (1...10000).contains(duration), arguments["duration_ms"] == nil || arguments["duration_ms"]?.int != nil else {
			throw ToolError("Drag duration must be 1 to 10000 milliseconds.")
		}
		if foreground {
			let send = {
				await foregroundDrag(
					snapshotID, to: toSnapshot?.string, from: from, through: waypoints, to: to,
					button: button == "right" ? .right : .left, milliseconds: duration, modifiers: modifiers
				)
			}
			if let expect = try expectation(arguments) { return try await expectAfter(expect, send) }
			return await send()
		}
		let points = [from] + waypoints + [to]
		let send = {
			await act("drag", snapshotID: snapshotID, element: nil) { snapshot, _ in
				let window = window(snapshot)
				try window.check()
				return try Mac.drag(points.map { globalPoint($0, in: window.bounds) }, button: button == "right" ? .right : .left, milliseconds: duration, window: window)
			}
		}
		if let expect = try expectation(arguments) { return try await expectAfter(expect, send) }
		return await send()
	}

	static func hover(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let (element, fraction) = try target(arguments)
		// Disabled controls still show tooltips.
		let point: @Sendable (Snapshot, Element?) -> CGPoint = { snapshot, target in
			fraction.map { globalPoint($0, in: snapshot.windowBounds) } ?? CGPoint(x: target!.frame.midX, y: target!.frame.midY)
		}
		return await act("hover", snapshotID: snapshotID, element: element, allowsDisabled: true, precheck: { snapshot, target in
			guard Mac.exposes(point(snapshot, target), window: window(snapshot)) else {
				throw Refusal("DESKTOP_ACTION_FAILED", "Another window covers this point, or the window moved since the snapshot. Inspect the window again; bring it forward with desktop_focus if it is covered.")
			}
		}) { snapshot, target in
			try Mac.hover(at: point(snapshot, target), window: window(snapshot))
		}
	}

	/// Exactly one of an element ID and a point, as click, scroll and hover take them.
	static func target(_ arguments: JSON) throws -> (element: String?, fraction: CGPoint?) {
		let element = arguments["element"]
		let point = arguments["point"]
		guard (element == nil) != (point == nil) else {
			throw ToolError("Choose exactly one observed element ID or normalized screenshot point.")
		}
		if point == nil, element?.string.map({ (1...256).contains($0.count) }) != true {
			throw ToolError("Choose an element ID from the inspected snapshot.")
		}
		return (element?.string, try fraction(point))
	}
}
