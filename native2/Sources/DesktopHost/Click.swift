import ApplicationServices
import CoreGraphics
import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

extension Tools {
	static func click(_ arguments: JSON) async throws -> ToolResult {
		let snapshotID = try snapshotArgument(arguments)
		let (element, fraction) = try target(arguments)
		guard let kind = ClickKind(rawValue: arguments["kind"]?.string ?? "single") else {
			throw ToolError("Choose single, double, right, middle, or triple click.")
		}
		let modifiers = try clickModifiers(arguments, kind: kind)
		let send = {
			if let modifiers { return await modifierClick(snapshotID, element: element, fraction: fraction, kind: kind, modifiers: modifiers) }
			return try await clickOnce(snapshotID, element: element, fraction: fraction, kind: kind)
		}
		if let expect = try expectation(arguments) { return try await expectAfter(expect, send) }
		return try await send()
	}

	private static func clickOnce(_ snapshotID: String, element: String?, fraction: CGPoint?, kind: ClickKind) async throws -> ToolResult {
		await act("click", snapshotID: snapshotID, element: element) { snapshot, target in
			let window = window(snapshot)
			let global = fraction.map { globalPoint($0, in: window.bounds) } ?? CGPoint(x: target!.frame.midX, y: target!.frame.midY)
			try window.check()
			Hooks.showPointer(.click(at: global, kind: kind, window: window.windowID))
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
