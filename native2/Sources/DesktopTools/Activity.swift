import AppKit
import CoreGraphics
import Darwin
import DesktopHost
import DesktopMac
import DesktopProtocol
import Foundation

// Ported from native/Sources/runtime's activity.swift. The Bridge named operations; native2 names tool calls, so
// each tool takes the name its Peekaboo operation had.

/// One recent operation as the app's menu shows it: what ran, for whom, where, and how it ended.
/// It never holds typed text, clipboard contents or values; only the operation and its target.
struct ActivityEntry: Encodable, Equatable {
	/// Seconds since 1970 of the latest repeat.
	var time: Double
	/// The caller's name, as approved: the nearest ancestor of the client that isn't a launcher or shell.
	let agent: String
	/// The caller's process, such as Claude Code or a terminal app.
	let pid: Int32
	let operation: String
	let app: String?
	let window: String?
	let outcome: String
	/// How many identical operations in a row this entry stands for.
	var count: Int
}

/// The last few operations, in memory; `ActivityLog` writes them to disk when the embedding app names a file.
final class Activity: @unchecked Sendable {
	static let shared = Activity()
	static let limit = 20
	private let lock = NSLock()
	private var entries: [ActivityEntry] = []

	/// Adds an entry, folding it into the newest one when only the time differs.
	func append(_ entry: ActivityEntry) {
		lock.lock()
		defer { lock.unlock() }
		if var last = entries.last, last.agent == entry.agent, last.pid == entry.pid, last.operation == entry.operation,
		   last.app == entry.app, last.window == entry.window, last.outcome == entry.outcome
		{
			last.time = entry.time
			last.count += 1
			entries[entries.count - 1] = last
			return
		}
		entries.append(entry)
		if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
	}

	/// Newest first.
	func read() -> [ActivityEntry] {
		lock.lock()
		defer { lock.unlock() }
		return entries.reversed()
	}
}

/// Appends each listed operation, and the embedding app's own notes, to a file the app names, one line each, so
/// its user can read all of it, not just what the menu holds. Lines carry only what the menu would show.
final class ActivityLog: @unchecked Sendable {
	static let shared = ActivityLog()
	/// Past this size the file moves to `<path>.1`, replacing the previous one, and a new file starts.
	static let limit: off_t = 1 << 20
	private let lock = NSLock()
	private var path: String?
	private var descriptor: Int32 = -1
	private static let format: DateFormatter = {
		let format = DateFormatter()
		format.locale = Locale(identifier: "en_US_POSIX")
		format.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return format
	}()

	/// Starts writing to `path`, readable only by the user, or stops when it is nil.
	func open(_ path: String?) {
		lock.lock()
		defer { lock.unlock() }
		if descriptor >= 0 { close(descriptor) }
		descriptor = -1
		self.path = path
		reopen()
	}

	func record(_ entry: ActivityEntry) {
		write(Self.message(entry), at: Date(timeIntervalSince1970: entry.time))
	}

	/// What a line says about one entry: operation · app — window · agent (pid) · outcome.
	static func message(_ entry: ActivityEntry) -> String {
		let target = [entry.app, entry.window].compactMap { $0 }.joined(separator: " — ")
		return [entry.operation, target.isEmpty ? nil : target, "\(entry.agent) (\(entry.pid))", entry.outcome]
			.compactMap { $0 }.joined(separator: " · ")
	}

	/// One whole line, in the local time zone.
	static func line(_ message: String, at time: Date) -> String {
		format.string(from: time) + "  " + message.replacingOccurrences(of: "\n", with: " ") + "\n"
	}

	func write(_ message: String, at time: Date = Date()) {
		lock.lock()
		defer { lock.unlock() }
		guard descriptor >= 0 else { return }
		let line = Self.line(message, at: time)
		_ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
		var info = stat()
		if fstat(descriptor, &info) == 0, info.st_size > Self.limit {
			close(descriptor)
			descriptor = -1
			reopen()
		}
	}

	/// Opens the file, moving it aside first when it is over the limit. Called with the lock held.
	private func reopen() {
		guard let path else { return }
		var info = stat()
		if stat(path, &info) == 0, info.st_size > Self.limit { rename(path, path + ".1") }
		descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
	}
}

/// Names shown for the tools worth listing, as the old runtime named their Peekaboo operations: every desktop
/// change, plus captures and clipboard reads, which reveal what is on screen or copied. Listings stay out, so they
/// don't crowd the menu.
let activityNames: [String: String] = [
	"desktop_screen": "Capture",
	"desktop_inspect": "Capture",
	"desktop_read": "Capture",
	"desktop_clipboard_read": "Read clipboard",
	"desktop_clipboard_write": "Write clipboard",
	"desktop_menu": "Menu command",
	"desktop_click": "Click",
	"desktop_set_value": "Set value",
	"desktop_set_cell": "Set value",
	"desktop_element_action": "Accessibility action",
	"desktop_notification_action": "Accessibility action",
	"desktop_key": "Key",
	"desktop_system_key": "System key",
	"desktop_switch_space": "System key",
	"desktop_input_source": "Select input source",
	"desktop_type": "Type",
	"desktop_select": "Select text",
	"desktop_fill_password": "Fill password",
	"desktop_insert": "Insert text",
	"desktop_scroll": "Scroll",
	"desktop_drag": "Drag",
	"desktop_hover": "Move pointer",
	"desktop_press": "Press",
	"desktop_launch": "Launch",
	"desktop_open": "Launch",
	// The Bridge refuses background unhide; activation is the route that unhides an app.
	"desktop_activate": "Activate",
	"desktop_unhide": "Activate",
	"desktop_quit": "Quit",
	"desktop_hide": "Hide",
	"desktop_close": "Close window",
	"desktop_focus": "Focus window",
	"desktop_minimize": "Minimize",
	"desktop_restore": "Restore",
	"desktop_maximize": "Maximize",
	"desktop_fullscreen": "Full screen",
	"desktop_move": "Move window",
	"desktop_resize": "Resize window",
	"desktop_dialog_answer": "Dialog text",
	"desktop_menubar_click": "Menu bar click",
	"desktop_dock": "Dock click",
]

/// The media, volume and brightness keys, which the Bridge sent as system-defined keys.
let mediaKeys: Set<String> = [
	"play_pause", "next_track", "previous_track", "volume_up", "volume_down", "mute", "brightness_up", "brightness_down",
	"keyboard_brightness_up", "keyboard_brightness_down",
]

/// The name a call is listed under, or nil when it isn't listed. Tools with several Peekaboo operations take the
/// name of the one their arguments chose; a Dock listing changes nothing, though the tool can.
func activityName(_ tool: String, arguments: JSON, mutatesDesktop: Bool) -> String? {
	switch tool {
	case "desktop_dock":
		guard arguments["title"] != nil else { return nil }
		return arguments["menu_item"] != nil ? "Dock menu" : "Dock click"
	case "desktop_dialog_answer":
		if arguments["button"] != nil { return "Dialog button" }
		if arguments["path"] != nil { return "File dialog path" }
	case "desktop_system_key":
		if let key = arguments["key"]?.string, mediaKeys.contains(key) { return "Media key" }
	case "desktop_insert":
		if arguments["format"] != nil { return "Insert attachment" }
	case "desktop_input_source":
		// Without select it only lists the sources, which the old runtime didn't log.
		if arguments["select"] == nil { return nil }
	default:
		break
	}
	return activityNames[tool] ?? (mutatesDesktop ? tool : nil)
}

/// How an entry ended: a refusal the user's pause caused says paused.
func activityOutcome(_ outcome: Hooks.Operation.Outcome, mutatesDesktop: Bool, paused: Bool) -> String {
	switch outcome {
	case .completed: "completed"
	case .unknown: "unknown"
	// The Bridge reported a request that failed before dispatch as refused.
	case .refused, .error: paused && mutatesDesktop ? "paused" : "refused"
	}
}

/// Records one finished call when it is worth listing. Runs while the client still waits for its reply,
/// so the client's environment and parent are still readable.
@Sendable func recordActivity(_ record: Hooks.Operation) {
	guard let name = activityName(record.tool, arguments: record.arguments, mutatesDesktop: record.mutatesDesktop) else { return }
	let caller = Callers.shared.resolve(client: record.client)
	let parent = parentProcess(of: record.client)
	let entry = ActivityEntry(
		time: Date().timeIntervalSince1970,
		agent: caller?.caller.name ?? parent.flatMap(processName) ?? "Unknown agent",
		pid: caller?.pid ?? parent ?? record.client,
		operation: name,
		app: record.targetProcess.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName },
		window: record.targetWindow.flatMap(windowTitle),
		outcome: activityOutcome(record.outcome, mutatesDesktop: record.mutatesDesktop, paused: Pause.shared.isPaused),
		count: 1
	)
	Activity.shared.append(entry)
	ActivityLog.shared.record(entry)
}

private func parentProcess(of process: pid_t) -> pid_t? {
	var info = kinfo_proc()
	var size = MemoryLayout<kinfo_proc>.stride
	var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process]
	guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
	let parent = info.kp_eproc.e_ppid
	return parent > 1 ? parent : nil
}

private func processName(_ process: pid_t) -> String? {
	var buffer = [CChar](repeating: 0, count: 256)
	guard proc_name(process, &buffer, UInt32(buffer.count)) > 0 else { return nil }
	let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
	return name.isEmpty ? nil : name
}

/// The window's title as WindowServer lists it, cut short for the menu.
private func windowTitle(_ window: CGWindowID) -> String? {
	guard let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]],
	      let title = rows.first?[kCGWindowName as String] as? String, !title.isEmpty
	else { return nil }
	return title.count > 60 ? String(title.prefix(59)) + "…" : title
}
