import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

/// Windows of the receiving process that appeared after an action was dispatched.
struct CreatedWindows: Encodable {
	let windows: [Window]
	/// exclusive when exactly one window appeared, ambiguous when several did, none when no window appeared.
	let attribution: String
	let note: String
}

/// Every window ID WindowServer knows, on screen or not; taken just before dispatch.
func existingWindowIDs() -> Set<Int> {
	let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
	return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
}

/// Waits briefly for a new normal window of the process, then lists its new inventory windows. Never sends input.
func createdWindows(
	_ client: PeekabooBridgeClient, process: ApplicationProcessIdentity, before: Set<Int>, waitingUpTo seconds: Double
) async -> CreatedWindows? {
	let deadline = Date().addingTimeInterval(seconds)
	repeat {
		let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
		let appeared = list.contains { info in
			(info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier
				&& (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
				&& !before.contains((info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)
		}
		if appeared {
			// Windows open in quick succession, as with several documents; let them settle.
			try? await Task.sleep(nanoseconds: 250_000_000)
			break
		}
		try? await Task.sleep(nanoseconds: 125_000_000)
	} while Date() < deadline
	guard let inventory = try? await client.listWindowMutationInventory(
		target: .application("PID:\(process.processIdentifier)")
	) else { return nil }
	let windows = inventory.items.filter { item in
		!before.contains(item.windowID) && item.mutationIdentity?.processIdentity == process
	}.map { Window($0, pid: process.processIdentifier) }
	switch windows.count {
	case 0:
		return CreatedWindows(windows: [], attribution: "none", note: "No new window of the app appeared within about \(Int(seconds.rounded())) second\(seconds < 1.5 ? "" : "s"). One may still open later, or the action may reuse an existing window; list desktop_windows before acting.")
	case 1:
		return CreatedWindows(windows: windows, attribution: "exclusive", note: "This is the only window of the app that appeared after the action was sent, so it is very likely the one the action opened. Another agent acting on the same app at the same moment can still open a window in this interval; if that matters, confirm its contents with desktop_inspect.")
	default:
		return CreatedWindows(windows: windows, attribution: "ambiguous", note: "Several windows of the app appeared after the action was sent. The action may have opened more than one, or something else opened the others at the same time; nothing here says which came from this action. Inspect them, or ask the user, before choosing one.")
	}
}
