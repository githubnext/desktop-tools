import AppKit
import CoreGraphics
import Darwin
import Foundation
import PeekabooBridge

/// One recent operation as the app's menu shows it: what ran, for whom, where, and how it ended.
/// It never holds typed text, clipboard contents or values; only the operation and its target.
struct ActivityEntry: Encodable, Equatable {
	/// Seconds since 1970 of the latest repeat.
	var time: Double
	/// The agent's name from DESKTOP_TOOLS_AGENT, or the name of the process that ran the client.
	let agent: String
	/// The process that ran the client, such as the MCP server; it lives as long as the agent's session.
	let pid: Int32
	let operation: String
	let app: String?
	let window: String?
	let outcome: String
	/// How many identical operations in a row this entry stands for.
	var count: Int
}

/// The last few operations, in memory only; nothing is written to disk.
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

/// Names shown for the operations worth listing: every desktop change, plus captures and clipboard reads, which
/// reveal what is on screen or copied. Snapshot bookkeeping and plain listings stay out, so they don't crowd the menu.
private let activityNames: [PeekabooBridgeOperation: String] = [
	.desktopObservation: "Capture",
	.clipboardTextRead: "Read clipboard",
	.clipboardImageRead: "Read clipboard",
	.clipboardImageExport: "Read clipboard",
	.clipboardFilesRead: "Read clipboard",
	.clipboardTextWrite: "Write clipboard",
	.clipboardImageWrite: "Write clipboard",
	.clipboardFilesWrite: "Write clipboard",
	.menuCommand: "Menu command",
	.targetedClick: "Click",
	.exactWindowTargetedClick: "Click",
	.foregroundModifierClick: "Click",
	.setValue: "Set value",
	.performAction: "Accessibility action",
	.exactWindowTargetedHotkey: "Key",
	.hotkey: "System key",
	.systemDefinedKey: "Media key",
	.selectInputSource: "Select input source",
	.exactWindowTargetedTypeActions: "Type",
	.selectText: "Select text",
	.literalInsert: "Insert text",
	.attachmentInsert: "Insert attachment",
	.targetedScroll: "Scroll",
	.exactWindowDrag: "Drag",
	.drag: "Drag",
	.moveMouse: "Move pointer",
	.beginExactWindowHeldPointer: "Press",
	.launchApplicationWithOptions: "Launch",
	.activateApplication: "Activate",
	.quitApplication: "Quit",
	.hideApplication: "Hide",
	.backgroundCloseWindow: "Close window",
	.focusWindow: "Focus window",
	.minimizeWindow: "Minimize",
	.restoreWindow: "Restore",
	.maximizeWindow: "Maximize",
	.setWindowFullScreen: "Full screen",
	.moveWindow: "Move window",
	.resizeWindow: "Resize window",
	.exactDialogClickButton: "Dialog button",
	.exactDialogEnterText: "Dialog text",
	.exactFileDialogPath: "File dialog path",
	.clickMenuBarItemIndex: "Menu bar click",
	.launchDockItem: "Dock click",
	.rightClickDockItem: "Dock menu",
]

/// Operations that change nothing a user would notice, even when their result contract counts them as mutations.
private let activityHidden: Set<PeekabooBridgeOperation> = [
	.createSnapshot, .cleanSnapshot, .beginSnapshotMutation, .finishSnapshotMutation,
	.createExactWindowHeldPointerOwner, .releaseExactWindowHeldPointer, .revokeExactWindowHeldPointer,
	.disconnectExactWindowHeldPointerOwner, .prepareDialogAction,
]

/// Pause all input: while on, the runtime refuses every operation that changes the desktop, and clipboard writes,
/// before dispatch. Only the embedding app sets it, from its own menu; clients have no way to change it.
final class Pause: @unchecked Sendable {
	static let shared = Pause()
	static let message = "Input is paused in Desktop Tools, so nothing was sent. Ask the user to resume input from the Desktop Tools menu; reading the desktop still works."
	private let lock = NSLock()
	private var paused = false

	var isPaused: Bool {
		lock.lock()
		defer { lock.unlock() }
		return paused
	}

	func set(_ value: Bool) {
		lock.lock()
		paused = value
		lock.unlock()
	}

	/// The refusal for one request, or nil when it may run.
	func refusal(_ operation: PeekabooBridgeOperation, mutatesDesktop: Bool) -> String? {
		isPaused && Self.blocks(operation, mutatesDesktop: mutatesDesktop) ? Self.message : nil
	}

	/// Desktop changes and clipboard writes, but never snapshot bookkeeping or releasing a held button.
	static func blocks(_ operation: PeekabooBridgeOperation, mutatesDesktop: Bool) -> Bool {
		if pauseExempt.contains(operation) { return false }
		return mutatesDesktop || clipboardWrites.contains(operation)
	}
}

private let clipboardWrites: Set<PeekabooBridgeOperation> = [.clipboardTextWrite, .clipboardImageWrite, .clipboardFilesWrite]

/// Reads and cleanup keep working while paused, so a paused agent can still observe and nothing stays held.
private let pauseExempt: Set<PeekabooBridgeOperation> = [
	.createSnapshot, .cleanSnapshot, .ownsSnapshot, .getDetectionResult, .finishSnapshotMutation,
	.releaseExactWindowHeldPointer, .revokeExactWindowHeldPointer, .disconnectExactWindowHeldPointerOwner,
]

/// Records one finished request when it is worth listing. Runs while the client still waits for its reply,
/// so the client's environment and parent are still readable.
func recordActivity(_ record: PeekabooBridgeOperationRecord) {
	let operation = record.operation
	guard !activityHidden.contains(operation),
		let name = activityNames[operation] ?? (record.mutatesDesktop ? operation.rawValue : nil)
	else { return }
	let parent = parentProcess(of: record.clientProcessIdentifier)
	let agent = agentName(of: record.clientProcessIdentifier)
		?? parent.flatMap(processName)
		?? "Unknown agent"
	Activity.shared.append(ActivityEntry(
		time: Date().timeIntervalSince1970,
		agent: agent,
		pid: parent ?? record.clientProcessIdentifier,
		operation: name,
		app: record.targetProcessIdentifier.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName },
		window: record.targetWindowID.flatMap(windowTitle),
		outcome: record.outcome == .refused && Pause.shared.isPaused
			&& Pause.blocks(operation, mutatesDesktop: record.mutatesDesktop) ? "paused" : record.outcome.rawValue,
		count: 1
	))
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
	let name = String(cString: buffer)
	return name.isEmpty ? nil : name
}

/// The window's title as WindowServer lists it, cut short for the menu.
private func windowTitle(_ window: CGWindowID) -> String? {
	guard let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]],
		let title = rows.first?[kCGWindowName as String] as? String, !title.isEmpty
	else { return nil }
	return title.count > 60 ? String(title.prefix(59)) + "…" : title
}
