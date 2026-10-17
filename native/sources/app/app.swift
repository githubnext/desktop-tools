import AppKit
import Darwin

// The runtime is loaded, not linked, so the app stays a thin host for the same library embedding apps ship.
private struct Runtime {
	let start: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
	let status: @convention(c) () -> UnsafeMutablePointer<CChar>?
	let stop: @convention(c) () -> Void
	let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
	let permission: @convention(c) (UnsafePointer<CChar>) -> Void

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
	}
}

private struct Status: Decodable {
	var state: String
	var error: String?
	var accessibility: Bool
	var screenRecording: Bool
	var eventSynthesizing: Bool
}

@MainActor
private final class Host: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private let runtime: Runtime
	private let socket: String
	private let client: String
	private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	private let menu = NSMenu()
	private var serving = true

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
		menu.addItem(.separator())
		menu.addItem(withTitle: "Quit Desktop Tools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
	}

	@objc private func grant(_ sender: NSMenuItem) {
		(sender.representedObject as! String).withCString(runtime.permission)
	}

	@objc private func toggle() {
		serving.toggle()
		if serving { runtime.start(socket, client) } else { runtime.stop() }
	}
}

let app = NSApplication.shared
private let host = MainActor.assumeIsolated { Host() }
app.delegate = host
app.setActivationPolicy(.accessory)
app.run()
