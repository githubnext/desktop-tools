import AppKit
import Darwin

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
	}
}

private struct Status: Decodable {
	var state: String
	var error: String?
	var accessibility: Bool
	var screenRecording: Bool
	var eventSynthesizing: Bool
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

/// The menu lists this many recent operations; the rest are under All Activity.
private let recentShown = 5

@MainActor
private final class Host: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private let runtime: Runtime
	private let socket: String
	private let client: String
	private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let menu = NSMenu()
	private var serving = true
	// The app shows the agent cursor and window outline unless the user turned them off; embedding apps start with them off.
	private var cursor = UserDefaults.standard.object(forKey: "agentCursor") as? Bool ?? true
	private var highlight = UserDefaults.standard.object(forKey: "agentWindow") as? Bool ?? true

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
		super.init()
	}

	func applicationDidFinishLaunching(_: Notification) {
		item.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Desktop Tools")
		menu.delegate = self
		item.menu = menu
		runtime.setCursor(cursor)
		runtime.setHighlight(highlight)
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
		menu.addItem(.separator())
		renderActivity()
		menu.addItem(.separator())
		menu.addItem(withTitle: "Quit Desktop Tools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
		let symbol = ["completed": "checkmark.circle", "refused": "xmark.circle"][entry.outcome] ?? "questionmark.circle"
		item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.outcome)
		return item
	}

	@objc private func grant(_ sender: NSMenuItem) {
		(sender.representedObject as! String).withCString(runtime.permission)
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

	@objc private func toggleHighlight() {
		highlight.toggle()
		UserDefaults.standard.set(highlight, forKey: "agentWindow")
		runtime.setHighlight(highlight)
	}
}

let app = NSApplication.shared
private let host = MainActor.assumeIsolated { Host() }
app.delegate = host
app.setActivationPolicy(.accessory)
app.run()
