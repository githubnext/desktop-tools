@testable import DesktopTools
import DesktopHost
import DesktopProtocol
import Foundation
import Testing

struct ActivityTests {
	@Test
	func `tools take the names their Peekaboo operations had`() {
		#expect(activityName("desktop_inspect", arguments: .object([]), mutatesDesktop: false) == "Capture")
		#expect(activityName("desktop_clipboard_read", arguments: .object([]), mutatesDesktop: false) == "Read clipboard")
		#expect(activityName("desktop_click", arguments: .object([]), mutatesDesktop: true) == "Click")
		#expect(activityName("desktop_hover", arguments: .object([]), mutatesDesktop: true) == "Move pointer")
		#expect(activityName("desktop_unhide", arguments: .object([]), mutatesDesktop: true) == "Activate")
		#expect(activityName("desktop_switch_space", arguments: .object([]), mutatesDesktop: true) == "System key")
	}

	@Test
	func `listings stay out, and an unnamed change shows its tool`() {
		for tool in ["desktop_apps", "desktop_windows", "desktop_menus", "desktop_dialog", "desktop_wait", "desktop_spaces"] {
			#expect(activityName(tool, arguments: .object([]), mutatesDesktop: false) == nil)
		}
		#expect(activityName("desktop_dock", arguments: .object([]), mutatesDesktop: true) == nil)
		#expect(activityName("desktop_new_thing", arguments: .object([]), mutatesDesktop: true) == "desktop_new_thing")
	}

	@Test
	func `a tool's arguments pick which operation it was`() {
		#expect(activityName("desktop_dock", arguments: .object([("title", "Finder")]), mutatesDesktop: true) == "Dock click")
		#expect(activityName("desktop_dock", arguments: .object([("title", "Finder"), ("menu_item", "New Window")]), mutatesDesktop: true) == "Dock menu")
		#expect(activityName("desktop_dialog_answer", arguments: .object([("button", "OK")]), mutatesDesktop: true) == "Dialog button")
		#expect(activityName("desktop_dialog_answer", arguments: .object([("path", "/tmp")]), mutatesDesktop: true) == "File dialog path")
		#expect(activityName("desktop_dialog_answer", arguments: .object([("field", 0), ("text", "a")]), mutatesDesktop: true) == "Dialog text")
		#expect(activityName("desktop_system_key", arguments: .object([("key", "mute")]), mutatesDesktop: true) == "Media key")
		#expect(activityName("desktop_system_key", arguments: .object([("key", "tab")]), mutatesDesktop: true) == "System key")
		#expect(activityName("desktop_insert", arguments: .object([("format", "image")]), mutatesDesktop: true) == "Insert attachment")
		#expect(activityName("desktop_insert", arguments: .object([("text", "hi")]), mutatesDesktop: true) == "Insert text")
	}

	@Test
	func `a refusal while paused says paused, but only for input`() {
		#expect(activityOutcome(.refused, mutatesDesktop: true, paused: true) == "paused")
		#expect(activityOutcome(.refused, mutatesDesktop: false, paused: true) == "refused")
		#expect(activityOutcome(.refused, mutatesDesktop: true, paused: false) == "refused")
		#expect(activityOutcome(.error, mutatesDesktop: false, paused: false) == "refused")
		#expect(activityOutcome(.unknown, mutatesDesktop: true, paused: true) == "unknown")
		#expect(activityOutcome(.completed, mutatesDesktop: true, paused: false) == "completed")
	}

	@Test
	func `log lines read as the old runtime wrote them`() {
		let entry = ActivityEntry(time: 0, agent: "claude-code", pid: 42, operation: "Click", app: "TextEdit",
			window: "Untitled", outcome: "completed", count: 1)
		#expect(ActivityLog.message(entry) == "Click · TextEdit — Untitled · claude-code (42) · completed")
		let bare = ActivityEntry(time: 0, agent: "Unknown agent", pid: 7, operation: "Read clipboard", app: nil,
			window: nil, outcome: "paused", count: 1)
		#expect(ActivityLog.message(bare) == "Read clipboard · Unknown agent (7) · paused")
		let line = ActivityLog.line("two\nlines", at: Date(timeIntervalSince1970: 0))
		#expect(line.hasSuffix("  two lines\n"))
		#expect(line.count == "yyyy-MM-dd HH:mm:ss".count + "  two lines\n".count)
	}

	@Test
	func `repeats fold into the newest entry`() {
		let activity = Activity()
		let entry = ActivityEntry(time: 1, agent: "a", pid: 1, operation: "Click", app: nil, window: nil, outcome: "completed", count: 1)
		activity.append(entry)
		var later = entry
		later.time = 2
		activity.append(later)
		#expect(activity.read() == [ActivityEntry(time: 2, agent: "a", pid: 1, operation: "Click", app: nil, window: nil, outcome: "completed", count: 2)])
		// The app reads these fields; a missing app or window is left out, as before.
		let rows = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(activity.read())) as! [[String: Any]]
		#expect(Set(rows[0].keys) == ["time", "agent", "pid", "operation", "outcome", "count"])
	}
}
