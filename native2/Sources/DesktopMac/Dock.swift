import AppKit
import ApplicationServices
import CoreGraphics
import DesktopProtocol
import Foundation

// The Dock, ported from Peekaboo's DockService listing, launch press and context-menu selection (MIT).

public struct DockItem: Sendable {
	public let index: Int
	public let title: String
	public let kind: String
	public let isRunning: Bool?
	public let bundleID: String?
	public let frame: CGRect?
}

/// Input went out but its effect is unknown, as when the menu item wasn't pressed after the right-click.
public struct DockUnconfirmed: Error {
	public let delivery: Delivery
	public let message: String
}

private struct DockElement {
	let index: Int
	let title: String
	let kind: String
	let element: AXUIElement
}

private func dockApp() -> NSRunningApplication? {
	NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
}

private func kind(role: String, subrole: String, title: String) -> String {
	if role == "AXSeparator" || subrole == "AXSeparator" { return "separator" }
	switch subrole {
	case "AXApplicationDockItem": return "application"
	case "AXFolderDockItem": return "folder"
	case "AXFileDockItem": return "file"
	case "AXURLDockItem": return "url"
	case "AXMinimizedWindowDockItem": return "minimized_window"
	default: return ["trash", "bin"].contains(title.lowercased()) ? "trash" : "unknown"
	}
}

/// A best-effort guess from the title: a running app of that name, else an app bundle of that name.
private func bundleID(for name: String) -> String? {
	if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name || $0.localizedName?.contains(name) == true }) {
		return app.bundleIdentifier
	}
	let file = name.hasSuffix(".app") ? name : "\(name).app"
	for folder in ["/Applications", "/System/Applications", "/Applications/Utilities", NSString(string: "~/Applications").expandingTildeInPath] {
		let path = (folder as NSString).appendingPathComponent(file)
		if FileManager.default.fileExists(atPath: path), let bundle = Bundle(path: path) { return bundle.bundleIdentifier }
	}
	return nil
}

private func dockElements(_ pid: pid_t) throws -> [DockElement] {
	let app = AXUIElementCreateApplication(pid)
	guard let list = (AX.value(app, kAXChildrenAttribute) as? [AXUIElement])?.first(where: { AX.string($0, kAXRoleAttribute) == "AXList" }) else {
		throw ToolError("Dock item list not found.")
	}
	return (AX.value(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).enumerated().compactMap { index, element in
		let title = AX.string(element, kAXTitleAttribute) ?? ""
		let kind = kind(role: AX.string(element, kAXRoleAttribute) ?? "", subrole: AX.string(element, kAXSubroleAttribute) ?? "", title: title)
		return kind == "separator" ? nil : DockElement(index: index, title: title, kind: kind, element: element)
	}
}

private func refusal(_ message: String, hint: String) -> Refusal { Refusal("DESKTOP_ACTION_FAILED", message, hint: hint) }

extension Mac {
	/// The Dock's process and its generation, as the receipt names them.
	public static var dockProcess: (pid: pid_t, generation: UInt64)? {
		guard let dock = dockApp(), let generation = startIdentity(dock.processIdentifier).value else { return nil }
		return (dock.processIdentifier, generation)
	}

	/// Dock items in Dock order, without separators.
	public static func dockItems() throws -> [DockItem] {
		guard let dock = dockApp() else { throw ToolError("Dock application not found or not running.") }
		return try dockElements(dock.processIdentifier).map { item in
			DockItem(index: item.index, title: item.title, kind: item.kind,
			         isRunning: item.kind == "application" ? AX.value(item.element, "AXIsApplicationRunning") as? Bool : nil,
			         bundleID: item.kind == "application" && !item.title.isEmpty ? bundleID(for: item.title) : nil,
			         frame: AX.frame(item.element))
		}
	}

	/// The one item with this exact title, resolved again in the Dock generation the caller observed.
	private static func dockItem(_ title: String, dock: (pid: pid_t, generation: UInt64)) throws -> AXUIElement {
		guard dockProcess.map({ $0 == dock }) == true else {
			throw refusal("Dock changed process generation before dispatch", hint: "Resolve the current Dock generation before retrying.")
		}
		let matches = try dockElements(dock.pid).filter { $0.title == title }
		guard matches.count == 1 else {
			throw refusal("Dock item '\(title)' changed identity or order before dispatch.", hint: "Refresh the Dock inventory before retrying.")
		}
		return matches[0].element
	}

	/// Presses the item, which launches or activates it. Throws Refusal before dispatch.
	public static func pressDockItem(_ title: String, dock: (pid: pid_t, generation: UInt64)) async throws -> Delivery {
		let element = UncheckedBox(try dockItem(title, dock: dock))
		let error = await withCheckedContinuation { continuation in
			Thread.detachNewThread { continuation.resume(returning: AXUIElementPerformAction(element.value, kAXPressAction as CFString)) }
		}
		guard error == .success else {
			var unknown = Delivery(state: .indeterminate, mechanism: "accessibility_action", evidence: "completion_unknown", units: 1)
			unknown.mode = "foreground"
			throw DockUnconfirmed(delivery: unknown, message: "Dock AXPress for '\(title)' returned without reliable dispatch evidence.")
		}
		var delivery = Delivery.accepted("accessibility_action")
		delivery.mode = "foreground"
		try? await Task.sleep(for: .milliseconds(200))
		return delivery
	}

	/// Right-clicks the item with the real pointer and presses the context-menu item with this exact title.
	/// Throws Refusal before the right-click and DockUnconfirmed after it.
	public static func dockMenu(_ title: String, item: String, dock: (pid: pid_t, generation: UInt64)) async throws -> Delivery {
		let element = try dockItem(title, dock: dock)
		guard let frame = AX.frame(element) else {
			throw refusal("Dock item '\(title)' changed geometry before dispatch.", hint: "Resolve the current Dock item before retrying.")
		}
		let center = CGPoint(x: frame.midX, y: frame.midY)
		let source = CGEventSource(stateID: .hidSystemState)
		for type in [CGEventType.mouseMoved, .rightMouseDown, .rightMouseUp] {
			CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: center, mouseButton: .right)?.post(tap: .cghidEventTap)
		}
		try? await Task.sleep(for: .milliseconds(50))
		var clicked = Delivery.accepted("global_events")
		clicked.mode = "foreground"
		let unsubmitted = DockUnconfirmed(delivery: clicked, message: "The Dock context-menu right-click was dispatched, but '\(item)' selection was not submitted.")
		// The menu takes a moment to open.
		try? await Task.sleep(for: .milliseconds(300))
		guard dockProcess.map({ $0 == dock }) == true else { throw unsubmitted }
		let menus = ((AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
			+ (AX.value(AXUIElementCreateSystemWide(), kAXChildrenAttribute) as? [AXUIElement] ?? []))
			.filter { menu in
				var pid: pid_t = 0
				return AX.string(menu, kAXRoleAttribute) == "AXMenu" && AXUIElementGetPid(menu, &pid) == .success && pid == dock.pid
			}
		var unique: [AXUIElement] = []
		for menu in menus where !unique.contains(where: { CFEqual($0, menu) }) { unique.append(menu) }
		guard unique.count == 1 else { throw unsubmitted }
		let matches = (AX.value(unique[0], kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { entry in
			guard let frame = AX.frame(entry), !frame.isEmpty else { return false }
			return AX.string(entry, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) == item
		}
		guard matches.count == 1 else { throw unsubmitted }
		let entry = UncheckedBox(matches[0])
		let error = await withCheckedContinuation { continuation in
			Thread.detachNewThread { continuation.resume(returning: AXUIElementPerformAction(entry.value, kAXPressAction as CFString)) }
		}
		guard error == .success else {
			var unknown = Delivery(state: .indeterminate, mechanism: "composite", evidence: "completion_unknown", units: 2)
			unknown.mode = "foreground"
			throw DockUnconfirmed(delivery: unknown,
			                      message: "The Dock context-menu right-click was dispatched, and selecting '\(item)' may also have been dispatched.")
		}
		var delivery = Delivery.accepted("composite", units: 2)
		delivery.mode = "foreground"
		return delivery
	}
}
