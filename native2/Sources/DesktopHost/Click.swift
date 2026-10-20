import ApplicationServices
import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

extension Tools {
	static func click(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let element = arguments["element"]
		let point = arguments["point"]
		guard (element == nil) != (point == nil) else {
			throw ToolError("Choose exactly one observed element ID or normalized screenshot point.")
		}
		let fraction = try Tools.fraction(point)
		if point == nil, element?.string.map({ (1...256).contains($0.count) }) != true {
			throw ToolError("Choose an element ID from the inspected snapshot.")
		}
		guard let kind = ClickKind(rawValue: arguments["kind"]?.string ?? "single") else {
			throw ToolError("Choose single, double, right, middle, or triple click.")
		}
		if arguments["modifiers"] != nil { throw ToolError("desktop_click's modifiers isn't in the Swift spike yet.") }
		if let expect = try expectation(arguments) {
			return try await expectAfter(expect) { try await clickOnce(snapshotID, element: element?.string, fraction: fraction, kind: kind) }
		}
		return try await clickOnce(snapshotID, element: element?.string, fraction: fraction, kind: kind)
	}

	private static func clickOnce(_ snapshotID: String, element: String?, fraction: CGPoint?, kind: ClickKind) async throws -> ToolResult {
		await act("click", snapshotID: snapshotID, element: element) { snapshot, target in
			let window = window(snapshot)
			let global = fraction.map { globalPoint($0, in: window.bounds) } ?? CGPoint(x: target!.frame.midX, y: target!.frame.midY)
			try window.check()
			switch (kind, target) {
			case (.single, let element?):
				do { return try Mac.clickElement(element.reference, window: window) } catch is Unsupported {
					return try Mac.clickPoint(global, window: window)
				}
			case (.single, nil):
				return try Mac.clickPoint(global, window: window)
			case (.right, let element?):
				do { return try Mac.showMenu(element.reference, window: window) } catch is Unsupported {
					return try Mac.routedClick(at: global, kind: kind, window: window)
				}
			default:
				return try Mac.routedClick(at: global, kind: kind, window: window)
			}
		}
	}
}
