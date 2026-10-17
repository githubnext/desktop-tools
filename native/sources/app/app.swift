import AppKit
import Darwin
import DesktopToolsCallers

// The runtime is loaded, not linked, so the app stays a thin host for the same library embedding apps ship.
private struct Runtime {
	let start: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
	let status: @convention(c) () -> UnsafeMutablePointer<CChar>?
	let stop: @convention(c) () -> Void
	let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
	let permission: @convention(c) (UnsafePointer<CChar>) -> Void
	let setCursor: @convention(c) (Bool) -> Void
	let setHighlight: @convention(c) (Bool) -> Void
	let activity: @convention(c) () -> UnsafeMutablePointer<CChar>?
	let setPaused: @convention(c) (Bool) -> Void
	let setCallerHandler: @convention(c) ((@convention(c) (UnsafePointer<CChar>) -> Void)?) -> Void
	let setCallers: @convention(c) (UnsafePointer<CChar>) -> Void
	let setPasswordAutofill: @convention(c) (Bool) -> Void
	let setConfirmationHandlers: @convention(c) (
		(@convention(c) (UInt64, UnsafePointer<CChar>) -> Void)?, (@convention(c) (UInt64) -> Void)?
	) -> Void
	let answerConfirmation: @convention(c) (UInt64, Bool) -> Void

	init(_ path: String) {
		guard let handle = dlopen(path, RTLD_NOW) else { fatalError(String(cString: dlerror())) }
		func symbol<T>(_ name: String) -> T {
			guard let pointer = dlsym(handle, name) else { fatalError("Missing \(name) in \(path)") }
			return unsafeBitCast(pointer, to: T.self)
		}
		start = symbol("desktop_tools_start")
		status = symbol("desktop_tools_status")
		stop = symbol("desktop_tools_stop")
		free = symbol("desktop_tools_free")
		permission = symbol("desktop_tools_permission")
		setCursor = symbol("desktop_tools_set_cursor")
		setHighlight = symbol("desktop_tools_set_highlight")
		activity = symbol("desktop_tools_activity")
		setPaused = symbol("desktop_tools_set_paused")
		setCallerHandler = symbol("desktop_tools_set_caller_handler")
		setCallers = symbol("desktop_tools_set_callers")
		setPasswordAutofill = symbol("desktop_tools_set_password_autofill")
		setConfirmationHandlers = symbol("desktop_tools_set_confirmation_handlers")
		answerConfirmation = symbol("desktop_tools_answer_confirmation")
	}
}

private struct Status: Decodable {
	var state: String
	var error: String?
	var accessibility: Bool
	var screenRecording: Bool
	var eventSynthesizing: Bool
	var paused: Bool?
}

/// One recent operation from the runtime, newest first; it never includes typed text or values.
private struct Activity: Decodable {
	var time: Double
	var agent: String
	var pid: Int32
	var operation: String
	var app: String?
	var window: String?
	var outcome: String
	var count: Int
}

/// A question the runtime asks the user, such as whether an agent may fill a password it supplied.
private struct Confirmation: Decodable {
	var key: String
	var title: String
	var message: String
	var allow: String
	var deny: String
}

/// The menu lists this many recent operations; the rest are under All Activity.
private let recentShown = 5

/// The runtime asks about an unknown caller on its own thread; the app answers on the main thread.
private let callerAsked: @convention(c) (UnsafePointer<CChar>) -> Void = { json in
	let data = Data(String(cString: json).utf8)
	DispatchQueue.main.async {
		MainActor.assumeIsolated { Host.current?.ask(about: data) }
	}
}

/// The runtime asks to confirm one action, such as filling a password, on the main thread and awaits the answer.
private let confirmationAsked: @convention(c) (UInt64, UnsafePointer<CChar>) -> Void = { id, json in
	let data = Data(String(cString: json).utf8)
	MainActor.assumeIsolated { Host.current?.confirm(id, data) }
}

/// The runtime stopped waiting for an answer, on the main thread; its prompt closes.
private let confirmationWithdrawn: @convention(c) (UInt64) -> Void = { id in
	MainActor.assumeIsolated { Confirmations.shared.cancel(key: confirmationKey(id)) }
}

/// Each request is its own question, so two password fills never share one answer.
private func confirmationKey(_ id: UInt64) -> String {
	"confirmation \(id)"
}

@MainActor
private final class Host: NSObject, NSApplicationDelegate, NSMenuDelegate {
	static weak var current: Host?
	private let runtime: Runtime
	private let socket: String
	private let client: String
	private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let menu = NSMenu()
	private var serving = true
	// Pausing lasts until the user resumes or the app quits; it is never saved.
	private var paused = false
	// The app shows the agent cursor and window outline unless the user turned them off; embedding apps start with them off.
	private var cursor = UserDefaults.standard.object(forKey: "agentCursor") as? Bool ?? true
	private var highlight = UserDefaults.standard.object(forKey: "agentWindow") as? Bool ?? true
	/// The user's answer for each caller, kept in the state directory; a missing file asks about every caller again.
	private let decisionsFile: URL
	private var decisions: [CallerDecision]
	/// Callers asked about and not answered yet, newest last.
	private var waiting: [Caller] = []
	// Agent-supplied passwords need the user's approval for each fill unless the user turned this on.
	private var passwords = UserDefaults.standard.bool(forKey: "agentPasswords")

	override init() {
		let bin = Bundle.main.executableURL!.deletingLastPathComponent()
		runtime = Runtime(bin.appendingPathComponent("libDesktopTools.dylib").path)
		// A development build takes another state directory so it never relinks the installed app's client.
		let state = ProcessInfo.processInfo.environment["DESKTOP_TOOLS_STATE"] ?? ""
		let home = state.isEmpty
			? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/desktop-tools")
			: URL(fileURLWithPath: state)
		try! FileManager.default.createDirectory(
			at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		// Consumers find the signed client through a stable link that follows the app wherever it is installed.
		let link = home.appendingPathComponent("desktop-client").path
		let pending = link + ".\(getpid())"
		unlink(pending)
		guard symlink(bin.appendingPathComponent("desktop-tools-client").path, pending) == 0,
			rename(pending, link) == 0
		else { fatalError("Cannot link the desktop client at \(link)") }
		socket = home.appendingPathComponent("desktop.sock").path
		client = Bundle.main.bundleIdentifier! + ".desktop-client"
		decisionsFile = home.appendingPathComponent(CallerDecisions.fileName)
		decisions = CallerDecisions.load(decisionsFile)
		super.init()
		Host.current = self
	}

	func applicationDidFinishLaunching(_: Notification) {
		updateIcon()
		menu.delegate = self
		item.menu = menu
		runtime.setCursor(cursor)
		runtime.setHighlight(highlight)
		pushDecisions()
		runtime.setCallerHandler(callerAsked)
		runtime.setPasswordAutofill(passwords)
		runtime.setConfirmationHandlers(confirmationAsked, confirmationWithdrawn)
		runtime.start(socket, client)
		render()
	}

	func applicationWillTerminate(_: Notification) {
		runtime.stop()
	}

	func menuNeedsUpdate(_: NSMenu) {
		render()
	}

	private func read() -> Status? {
		guard let pointer = runtime.status() else { return nil }
		defer { runtime.free(pointer) }
		return try? JSONDecoder().decode(Status.self, from: Data(String(cString: pointer).utf8))
	}

	private func render() {
		menu.removeAllItems()
		let status = read()
		let state = status.map { $0.error.map { "Error: \($0)" } ?? $0.state.capitalized } ?? "Unavailable"
			+ (paused ? " (input paused)" : "")
		menu.addItem(withTitle: "Desktop Tools: \(state)", action: nil, keyEquivalent: "")
		menu.addItem(withTitle: socket, action: nil, keyEquivalent: "")
		menu.addItem(.separator())
		let grants: [(String, String, Bool)] = [
			("Accessibility", "accessibility", status?.accessibility ?? false),
			("Screen Recording", "screenRecording", status?.screenRecording ?? false),
			("Keyboard input", "eventSynthesizing", status?.eventSynthesizing ?? false),
		]
		for (title, kind, granted) in grants {
			let entry = NSMenuItem(
				title: granted ? "\(title): granted" : "Grant \(title)…",
				action: granted ? nil : #selector(grant(_:)),
				keyEquivalent: "")
			entry.target = self
			entry.representedObject = kind
			entry.state = granted ? .on : .off
			menu.addItem(entry)
		}
		menu.addItem(.separator())
		renderCallers()
		let pause = NSMenuItem(title: "Pause All Input", action: #selector(togglePause), keyEquivalent: "")
		pause.target = self
		pause.state = paused ? .on : .off
		pause.toolTip = "Refuse every click, key, typing, window change and clipboard write from agents until resumed. Reading the screen still works."
		menu.addItem(pause)
		let toggle = NSMenuItem(title: "Serve agents", action: #selector(toggle), keyEquivalent: "")
		toggle.target = self
		toggle.state = serving ? .on : .off
		menu.addItem(toggle)
		let pointer = NSMenuItem(title: "Show agent cursor", action: #selector(toggleCursor), keyEquivalent: "")
		pointer.target = self
		pointer.state = cursor ? .on : .off
		menu.addItem(pointer)
		let outline = NSMenuItem(title: "Highlight agent's window", action: #selector(toggleHighlight), keyEquivalent: "")
		outline.target = self
		outline.state = highlight ? .on : .off
		menu.addItem(outline)
		let autofill = NSMenuItem(
			title: "Always Allow Agent-Supplied Passwords", action: #selector(togglePasswords), keyEquivalent: "")
		autofill.target = self
		autofill.state = passwords ? .on : .off
		autofill.toolTip = "Fill passwords that agents supply without asking each time. Keychain items still need macOS's approval."
		menu.addItem(autofill)
		menu.addItem(.separator())
		renderActivity()
		menu.addItem(.separator())
		menu.addItem(withTitle: "Quit Desktop Tools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
	}

	/// Approved Agents: every caller the user answered or hasn't yet, each with what the user can change.
	private func renderCallers() {
		let list = NSMenu()
		let rows: [(Caller, String, [(String, Selector)])] =
			waiting.map { ($0, "clock", [("Allow", #selector(allowCaller(_:))), ("Don't Allow", #selector(denyCaller(_:)))]) }
			+ decisions.sorted { $0.decided > $1.decided }.map {
				$0.allowed
					? ($0.caller, "checkmark.circle", [("Revoke", #selector(denyCaller(_:)))])
					: ($0.caller, "xmark.circle", [("Allow", #selector(allowCaller(_:))), ("Forget", #selector(forgetCaller(_:)))])
			}
		if rows.isEmpty {
			list.addItem(withTitle: "No agents have asked yet", action: nil, keyEquivalent: "")
		}
		for (caller, symbol, actions) in rows {
			let row = NSMenuItem(title: caller.name, action: nil, keyEquivalent: "")
			row.subtitle = caller.origin
			row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
			let choices = NSMenu()
			for (title, action) in actions {
				let choice = NSMenuItem(title: title, action: action, keyEquivalent: "")
				choice.target = self
				choice.representedObject = caller.key
				choices.addItem(choice)
			}
			row.submenu = choices
			list.addItem(row)
		}
		let agents = NSMenuItem(title: waiting.isEmpty ? "Approved Agents" : "Approved Agents (\(waiting.count) waiting)",
			action: nil, keyEquivalent: "")
		agents.submenu = list
		menu.addItem(agents)
	}

	/// Asks the user about a caller the runtime refused for now. The caller isn't waiting; it was told to retry.
	fileprivate func ask(about data: Data) {
		guard let caller = try? JSONDecoder().decode(Caller.self, from: data),
			!decisions.contains(where: { $0.caller.key == caller.key })
		else { return }
		waiting.removeAll { $0.key == caller.key }
		waiting.append(caller)
		Task {
			let answer = await Confirmations.shared.ask(.init(
				key: "caller \(caller.key)",
				title: "Allow \(caller.name) to control this Mac?",
				message: """
					\(caller.origin)

					It could see the screen, read the clipboard, and click, type and change apps and windows, with \
					the permissions you gave Desktop Tools. You can change this under Approved Agents in the \
					Desktop Tools menu.
					""",
				allow: "Allow",
				deny: "Don't Allow"))
			// nil: already answered from the menu.
			if let answer { decide(caller, allowed: answer == .allow) }
		}
	}

	private func decide(_ caller: Caller, allowed: Bool) {
		decisions.removeAll { $0.caller.key == caller.key }
		decisions.append(CallerDecision(caller: caller, allowed: allowed, decided: Date().timeIntervalSince1970))
		waiting.removeAll { $0.key == caller.key }
		Confirmations.shared.cancel(key: "caller \(caller.key)")
		saveDecisions()
	}

	private func caller(_ sender: NSMenuItem) -> Caller? {
		let key = sender.representedObject as? String
		return waiting.first { $0.key == key } ?? decisions.first { $0.caller.key == key }?.caller
	}

	@objc private func allowCaller(_ sender: NSMenuItem) {
		if let caller = caller(sender) { decide(caller, allowed: true) }
	}

	@objc private func denyCaller(_ sender: NSMenuItem) {
		if let caller = caller(sender) { decide(caller, allowed: false) }
	}

	/// Forgets a refused caller, so it is asked about again next time.
	@objc private func forgetCaller(_ sender: NSMenuItem) {
		decisions.removeAll { $0.caller.key == sender.representedObject as? String }
		saveDecisions()
	}

	private func saveDecisions() {
		// The runtime follows the answers even if the file can't be written; they last until the app quits.
		try? CallerDecisions.save(decisions, to: decisionsFile)
		pushDecisions()
	}

	private func pushDecisions() {
		let data = (try? JSONEncoder().encode(decisions)) ?? Data("[]".utf8)
		String(decoding: data, as: UTF8.self).withCString(runtime.setCallers)
	}

	private func readActivity() -> [Activity] {
		guard let pointer = runtime.activity() else { return [] }
		defer { runtime.free(pointer) }
		return (try? JSONDecoder().decode([Activity].self, from: Data(String(cString: pointer).utf8))) ?? []
	}

	/// The last few operations agents ran, so use from outside this app stays visible.
	private func renderActivity() {
		let entries = readActivity()
		menu.addItem(.sectionHeader(title: "Recent Activity"))
		if entries.isEmpty {
			menu.addItem(withTitle: "No agent activity since Desktop Tools started", action: nil, keyEquivalent: "")
			return
		}
		for entry in entries.prefix(recentShown) { menu.addItem(activityItem(entry)) }
		guard entries.count > recentShown else { return }
		let all = NSMenu()
		for entry in entries { all.addItem(activityItem(entry)) }
		let more = NSMenuItem(title: "All Activity (\(entries.count))", action: nil, keyEquivalent: "")
		more.submenu = all
		menu.addItem(more)
	}

	private func activityItem(_ entry: Activity) -> NSMenuItem {
		let target = [entry.app, entry.window].compactMap { $0 }.joined(separator: " — ")
		let repeats = entry.count > 1 ? " ×\(entry.count)" : ""
		let item = NSMenuItem(
			title: entry.operation + repeats + (target.isEmpty ? "" : " · \(target)"),
			action: nil,
			keyEquivalent: "")
		let time = Date(timeIntervalSince1970: entry.time).formatted(date: .omitted, time: .standard)
		item.subtitle = "\(entry.agent) (\(entry.pid)) · \(time) · \(entry.outcome)"
		let symbol = ["completed": "checkmark.circle", "refused": "xmark.circle", "paused": "pause.circle"][entry.outcome]
			?? "questionmark.circle"
		item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.outcome)
		return item
	}

	@objc private func grant(_ sender: NSMenuItem) {
		(sender.representedObject as! String).withCString(runtime.permission)
	}

	@objc private func togglePause() {
		paused.toggle()
		runtime.setPaused(paused)
		updateIcon()
	}

	/// The menu bar icon shows a pause sign while input is paused, so the state is visible at a glance.
	private func updateIcon() {
		let symbol = paused ? "pause.circle.fill" : "cursorarrow.rays"
		item.button?.image = NSImage(
			systemSymbolName: symbol,
			accessibilityDescription: paused ? "Desktop Tools, input paused" : "Desktop Tools")
		item.button?.toolTip = paused ? "Desktop Tools: input paused" : "Desktop Tools"
	}

	@objc private func toggle() {
		serving.toggle()
		if serving { runtime.start(socket, client) } else { runtime.stop() }
	}

	@objc private func toggleCursor() {
		cursor.toggle()
		UserDefaults.standard.set(cursor, forKey: "agentCursor")
		runtime.setCursor(cursor)
	}

	@objc private func togglePasswords() {
		passwords.toggle()
		UserDefaults.standard.set(passwords, forKey: "agentPasswords")
		runtime.setPasswordAutofill(passwords)
	}

	/// Asks the user, then answers the runtime; the runtime refuses on its own if nobody answers in time.
	fileprivate func confirm(_ id: UInt64, _ data: Data) {
		guard let request = try? JSONDecoder().decode(Confirmation.self, from: data) else {
			return runtime.answerConfirmation(id, false)
		}
		Task {
			let answer = await Confirmations.shared.ask(.init(
				key: confirmationKey(id), title: request.title, message: request.message, allow: request.allow,
				deny: request.deny))
			// nil: withdrawn after the runtime stopped waiting, so there is no one to answer.
			if let answer { runtime.answerConfirmation(id, answer == .allow) }
		}
	}

	@objc private func toggleHighlight() {
		highlight.toggle()
		UserDefaults.standard.set(highlight, forKey: "agentWindow")
		runtime.setHighlight(highlight)
	}
}

@main
private enum Main {
	@MainActor
	static func main() {
		let app = NSApplication.shared
		// The application holds its delegate weakly; this frame lives as long as the app runs.
		let host = Host()
		app.delegate = host
		app.setActivationPolicy(.accessory)
		app.run()
	}
}
