import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DesktopProtocol
import Foundation
import IOKit

// Secure keyboard entry blocks every synthesized key in every app, and the app holding it is often not the target:
// a system password dialog behind the target window holds it while its secure field has focus (#176). The window
// server records the holder's pid in the console session.

extension Mac {
	/// The pid of the process holding secure keyboard entry, from the session dictionary or IOConsoleUsers.
	static func secureInputPID() -> pid_t? {
		func pid(_ value: Any?) -> pid_t? { (value as? NSNumber).map { pid_t(truncating: $0) }.flatMap { $0 > 0 ? $0 : nil } }
		if let session = CGSessionCopyCurrentDictionary() as? [String: Any], let found = pid(session["kCGSSessionSecureInputPID"]) {
			return found
		}
		let root = IORegistryGetRootEntry(kIOMainPortDefault)
		defer { IOObjectRelease(root) }
		let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] ?? []
		return users.lazy.compactMap { pid($0["kCGSSessionSecureInputPID"]) }.first
	}

	/// The refusal for typing while secure keyboard entry is on, naming the app and window that hold it.
	public static func secureInputRefusal(fromHost: Bool = false) -> Refusal {
		var holder: [(String, JSON)] = []
		var named = "Another app"
		var short = named
		var window = ""
		if let pid = secureInputPID() {
			holder.append(("pid", JSON(Int(pid))))
			let app = NSRunningApplication(processIdentifier: pid)
			if let name = app?.localizedName { holder.append(("name", JSON(name))) }
			if let bundle = app?.bundleIdentifier { holder.append(("bundle_id", JSON(bundle))) }
			short = app?.localizedName ?? app?.bundleIdentifier ?? "process \(pid)"
			named = "\(short) (\([app?.bundleIdentifier, "pid \(pid)"].compactMap(\.self).joined(separator: ", ")))"
			let element = AXUIElementCreateApplication(pid)
			AXUIElementSetMessagingTimeout(element, 0.3)
			if let focused = AX.element(AX.value(element, kAXFocusedWindowAttribute)) {
				if let title = AX.string(focused, kAXTitleAttribute), !title.isEmpty {
					holder.append(("window_title", JSON(title)))
					window = " in its window \"\(title.count > 120 ? String(title.prefix(120)) + "…" : title)\""
				}
				if let id = AX.windowID(focused) { holder.append(("window_id", JSON(id))) }
			}
		}
		let message = holder.isEmpty
			? "Secure keyboard entry is on, as for a password field or a terminal's Secure Keyboard Entry, so typed text can't be delivered, and the app holding it couldn't be found. Nothing was typed."
			: "Secure keyboard entry is on, so typed text can't be delivered to any app. \(named) holds it\(window), as a focused password field or a terminal's Secure Keyboard Entry does. Nothing was typed."
		var refusal = Refusal(
			"DESKTOP_ACTION_FAILED", message,
			hint: holder.isEmpty
				? "Ask the user to close or complete any password prompt, or turn off Secure Keyboard Entry in the app that has it."
				: "Ask the user to dismiss or complete the password prompt in \(short), or turn off Secure Keyboard Entry there; agents can't answer system password prompts.",
			fromHost: fromHost
		)
		if !holder.isEmpty { refusal.fields = [("secure_input_holder", .object(holder))] }
		return refusal
	}
}
