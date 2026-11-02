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
		var modifiers = try clickModifiers(arguments, kind: kind)
		if try foregroundFlag(arguments) {
			guard [.single, .double, .triple].contains(kind) else {
				throw ToolError("foreground applies to single, double and triple clicks; right and middle clicks are already pointer events.")
			}
			modifiers = modifiers ?? []
		}
		let path = try arguments["menu_path"].map { try menuPath($0) }
		if path != nil, kind != .right {
			throw ToolError("menu_path chooses an item of the context menu a right click opens; set kind right.")
		}
		let send = {
			if let modifiers { return await modifierClick(snapshotID, element: element, fraction: fraction, kind: kind, modifiers: modifiers) }
			return try await clickOnce(snapshotID, element: element, fraction: fraction, kind: kind, menuPath: path)
		}
		if let expect = try expectation(arguments) { return try await expectAfter(expect, send) }
		return try await send()
	}

	private static func clickOnce(_ snapshotID: String, element: String?, fraction: CGPoint?, kind: ClickKind, menuPath: [String]?) async throws -> ToolResult {
		await act("click", snapshotID: snapshotID, element: element) { snapshot, target in
			let window = window(snapshot)
			let global = fraction.map { globalPoint($0, in: window.bounds) } ?? CGPoint(x: target!.frame.midX, y: target!.frame.midY)
			try window.check()
			Hooks.showPointer(.click(at: global, kind: kind, window: window.windowID))
			switch (kind, target) {
			case (.single, let element?):
				do { return try Mac.clickElement(element.reference, window: window, at: global) } catch is Unsupported {
					return try Mac.clickPoint(global, window: window)
				}
			case (.single, nil):
				return try Mac.clickPoint(global, window: window)
			case (.right, let element?):
				let opened: Delivery
				do { opened = try Mac.showMenu(element.reference, window: window) } catch is Unsupported {
					opened = try Mac.routedClick(at: global, kind: kind, window: window)
				}
				return try contextMenu(after: opened, pid: window.pid, path: menuPath)
			case (.right, nil):
				return try contextMenu(after: Mac.routedClick(at: global, kind: kind, window: window), pid: window.pid, path: menuPath)
			default:
				return try Mac.routedClick(at: global, kind: kind, window: window)
			}
		}
	}

	/// After a right click: the context menu it opened, listed, or with menu_path, the item chosen in the same call. A
	/// background app's context menu closes as soon as other input arrives, often before the next call (#227).
	static func contextMenu(after opened: Delivery, pid: pid_t, path: [String]?) throws -> Delivery {
		guard let menu = Mac.openContextMenu(pid: pid, seconds: path == nil ? 0.6 : 1) else {
			guard let path else { return opened }
			var delivery = opened
			delivery.unverified = true
			delivery.fields.append(("error", errorJSON(
				"DESKTOP_ACTION_FAILED",
				"The right click was sent, but no context menu that Accessibility can see opened within a second, so \(String(reflecting: path)) was not chosen.",
				hint: "Inspect the window to see what the right click did. Never repeat it blindly."
			)))
			return delivery
		}
		// The menu seen open confirms the right click arrived. AXShowMenu doesn't return while its menu is open, so it
		// reports a still-running or timed-out action even though it has done its part.
		var base = Delivery.accepted(opened.mechanism ?? "accessibility_action", units: opened.units ?? 1)
		base.fields = opened.fields
		let items = contextMenuJSON(Mac.contextMenuRows(menu))
		guard let path else {
			base.fields.append(("context_menu", .object([
				("open", true), ("items", items),
				("note", "A background app's context menu closes as soon as other input arrives, so it may be gone by the next call. To choose an item, right-click again with menu_path set to its path."),
			])))
			return base
		}
		func failed(_ refusal: Refusal, listing: Bool) -> Delivery {
			let closed = Mac.closeContextMenu(menu)
			var delivery = base
			delivery.unverified = true
			if listing { delivery.fields.append(("context_menu", .object([("items", items)]))) }
			delivery.fields.append(("error", errorJSON(
				refusal.code,
				refusal.message + (closed ? " The right click opened the menu and it was closed again without choosing anything." : " The right click opened the menu, and it may still be open; nothing in it was chosen."),
				hint: refusal.hint ?? "Inspect the window before trying again."
			)))
			return delivery
		}
		let item: AXUIElement
		switch Mac.contextMenuItem(menu, path: path) {
		case let .failure(refusal): return failed(refusal, listing: true)
		case let .success(found): item = found
		}
		let result: AXError
		do { result = try Mac.pressContextMenuItem(item, pid: pid) } catch let refusal as Refusal {
			return failed(refusal, listing: false)
		}
		guard result == .success else {
			if result == .actionUnsupported || result == .invalidUIElement {
				return failed(Refusal("DESKTOP_ACTION_FAILED", "The menu item \(String(reflecting: path.last!)) couldn't be pressed (\(result.rawValue))."), listing: false)
			}
			var delivery = Delivery(state: .indeterminate, mechanism: "composite", evidence: "completion_unknown", units: (base.units ?? 1) + 1)
			delivery.fields = base.fields + [("menu_path", .array(path.map(JSON.string)))]
			return delivery
		}
		var delivery = Delivery.accepted(base.mechanism == "accessibility_action" ? "accessibility_action" : "composite", units: (base.units ?? 1) + 1)
		delivery.fields = base.fields + [("menu_path", .array(path.map(JSON.string)))]
		return delivery
	}

	/// Each item's literal path, flagged when it is disabled or opens a submenu.
	static func contextMenuJSON(_ rows: [ContextMenuRow]) -> JSON {
		.array(rows.map { row in
			var fields: [(String, JSON)] = [("path", .array(row.path.map(JSON.string)))]
			if !row.enabled { fields.append(("enabled", false)) }
			if row.submenu { fields.append(("submenu", true)) }
			return .object(fields)
		})
	}
}
