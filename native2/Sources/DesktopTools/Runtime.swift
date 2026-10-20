import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import DesktopCore
import DesktopHost
import DesktopMac
import Foundation
import OSLog

// Ported from native/Sources/runtime's runtime.swift: the C ABI in docs/embed.md, serving DesktopHost's Server
// in place of Peekaboo's embedded Bridge runtime.

private struct Status: Encodable {
	var state = "stopped"
	var error: String?
	var accessibility = false
	var screenRecording = false
	var eventSynthesizing = false
	var clipboardRead = ClipboardPolicy()
	var cursor = false
	var highlight = false
	var paused = false
}

private final class State: @unchecked Sendable {
	private let lock = NSLock()
	private var value = Status()

	func set(_ phase: String, error: String? = nil) {
		lock.lock()
		defer { lock.unlock() }
		value.state = phase
		value.error = error
	}

	func read() -> Status {
		lock.lock()
		var result = value
		lock.unlock()
		result.accessibility = AXIsProcessTrusted()
		result.screenRecording = CGPreflightScreenCaptureAccess()
		result.eventSynthesizing = result.eventSynthesizing || CGPreflightPostEventAccess()
		result.clipboardRead = ClipboardPolicy.current()
		result.paused = Pause.shared.isPaused
		return result
	}

	func setCursor(_ enabled: Bool) {
		lock.lock()
		value.cursor = enabled
		lock.unlock()
	}

	func setHighlight(_ enabled: Bool) {
		lock.lock()
		value.highlight = enabled
		lock.unlock()
	}

	func recordEventSynthesizing(_ granted: Bool) {
		lock.lock()
		value.eventSynthesizing = value.eventSynthesizing || granted
		lock.unlock()
	}
}

private let state = State()
private let log = Logger(subsystem: "dev.githubnext.desktop-tools", category: "runtime")

/// identity.swift's SigningError, word for word, which the app shows when this process can't serve.
private struct SigningError: LocalizedError {
	var errorDescription: String? {
		"Native desktop tools require the host app and its client to be signed by the same team with an Apple Development or Developer ID identity."
	}
}

@MainActor
private final class Desktop {
	static let shared = Desktop()
	private var server: Server?
	private var tail: Task<Void, Never>?
	/// What the embedding app asked to serve, until it stops; a lost socket is published again from it.
	private var wanted: (socket: String, client: String)?
	private var watch: SocketWatch?
	/// A failed start is waiting to retry.
	private var retrying = false
	/// When the socket was last lost, so a socket that keeps disappearing is published again more slowly.
	private var lastLost = Date.distantPast

	private init() {
		Hooks.targetWindow = { target in
			// The requesting client is still waiting for its reply, so its environment is readable now.
			let agent = agentName(of: target.client)
			DispatchQueue.main.async {
				AgentCursor.shared.window = target.window
				AgentWindow.shared.target(window: target.window, process: target.process, agent: agent)
			}
		}
		Hooks.operation = recordActivity
		Hooks.secureTextFill = { await PasswordFill.shared.authorize($0) }
		Hooks.pointer = { feedback in await AgentCursor.shared.show(feedback) }
	}

	func start(socket: String, client: String, after pause: UInt64 = 0) {
		wanted = (socket, client)
		watch?.cancel()
		watch = nil
		retrying = false
		let previous = tail
		previous?.cancel()
		tail = Task {
			await previous?.value
			if pause > 0 {
				try? await Task.sleep(nanoseconds: pause * NSEC_PER_SEC)
				guard !Task.isCancelled else { return }
			}
			if let server {
				// The lease goes with the old server's last call; the new one can't serve until then.
				server.stop()
				await server.drained()
			}
			server = nil
			state.set("starting")
			// A failed start, such as a socket folder that can't be made yet, is retried.
			var delay: UInt64 = 1
			while !Task.isCancelled {
				do {
					guard let own = ownSigning() else { throw SigningError() }
					let next = Server(path: socket, client: ClientRequirement(team: own.team, identifier: client))
					try next.start()
					server = next
					retrying = false
					state.set("ready")
					// Desktop is a singleton, so holding it costs nothing.
					watch = SocketWatch(path: socket) { self.lost() }
					if watch == nil { lost() }
					return
				} catch {
					guard !Task.isCancelled else { return }
					log.error("Cannot serve the socket: \(error.localizedDescription, privacy: .public)")
					state.set("error", error: "\(error.localizedDescription) Retrying in \(delay)s.")
				}
				retrying = true
				try? await Task.sleep(nanoseconds: delay * NSEC_PER_SEC)
				delay = min(delay * 2, 30)
			}
		}
	}

	/// Checks now that the socket is still published, and retries a failed start at once instead of waiting.
	func check() {
		if let watch {
			watch.check()
		} else if retrying, let wanted {
			start(socket: wanted.socket, client: wanted.client)
		}
	}

	/// The socket path no longer names this host's socket, so no client can reach it: serve and publish it again.
	private func lost() {
		guard let wanted else { return }
		let message = "\(wanted.socket) was removed or replaced while serving. Publishing it again."
		log.error("\(message, privacy: .public)")
		ActivityLog.shared.write(message)
		state.set("error", error: message)
		// Losing it again within a minute waits first, so a path something keeps removing doesn't spin.
		let pause: UInt64 = Date().timeIntervalSince(lastLost) < 60 ? 5 : 0
		lastLost = Date()
		start(socket: wanted.socket, client: wanted.client, after: pause)
	}

	func stop() {
		wanted = nil
		watch?.cancel()
		watch = nil
		retrying = false
		let previous = tail
		previous?.cancel()
		tail = Task {
			await previous?.value
			state.set("stopping")
			if let server {
				server.stop()
				await server.drained()
			}
			server = nil
			state.set("stopped")
		}
	}
}

/// Starts serving `socket` for the exact signed `client` identifier from this process's team.
@_cdecl("desktop_tools_start")
public func start(_ socket: UnsafePointer<CChar>, _ client: UnsafePointer<CChar>) {
	let socket = String(cString: socket)
	let client = String(cString: client)
	// A client that closes its connection before the reply, such as one that only checks the socket accepts
	// connections, made a write raise SIGPIPE and killed the whole host, leaving its socket behind. A write to a
	// closed connection fails with EPIPE instead.
	signal(SIGPIPE, SIG_IGN)
	state.set("starting")
	// Bun's thread must not wait for work that needs the application's main run loop.
	DispatchQueue.main.async {
		Desktop.shared.start(socket: socket, client: client)
	}
}

/// Checks now that the socket started with `desktop_tools_start` is still published, publishes it again if it was
/// removed or replaced, and retries a failed start at once. The runtime also checks on its own; call this when a
/// client or the user reports that the host can't be reached, such as when the app is opened again.
@_cdecl("desktop_tools_check")
public func check() {
	DispatchQueue.main.async { Desktop.shared.check() }
}

/// Returns status JSON; release it with `desktop_tools_free`.
@_cdecl("desktop_tools_status")
public func status() -> UnsafeMutablePointer<CChar>? {
	let data = try! JSONEncoder().encode(state.read())
	return strdup(String(decoding: data, as: UTF8.self))
}

/// Stops serving once the calls already running finish, at most 30 seconds; poll status until `stopped`.
@_cdecl("desktop_tools_stop")
public func stop() {
	state.set("stopping")
	DispatchQueue.main.async { Desktop.shared.stop() }
}

/// Shows or hides the agent cursor drawn for pointer input; it is off until an embedding app turns it on.
@_cdecl("desktop_tools_set_cursor")
public func setCursor(_ enabled: Bool) {
	state.setCursor(enabled)
	DispatchQueue.main.async { AgentCursor.shared.enabled = enabled }
}

/// Shows or hides the outline and label on the window the agent is using; it is off until an embedding app turns it on.
@_cdecl("desktop_tools_set_highlight")
public func setHighlight(_ enabled: Bool) {
	state.setHighlight(enabled)
	DispatchQueue.main.async { AgentWindow.shared.enabled = enabled }
}

/// Pauses or resumes all input: while paused, every tool that changes the desktop, and clipboard writes, are
/// refused before dispatch, and reads keep working. Only the embedding app calls this; it starts resumed.
@_cdecl("desktop_tools_set_paused")
public func setPaused(_ paused: Bool) {
	Pause.shared.set(paused)
}

/// Turns on caller approval: from now on a request runs only when the user allowed its caller, the nearest
/// ancestor of the client that isn't a launcher or shell. The first request from an unknown caller is refused, and
/// `handler` gets that caller as JSON (`key`, `name`, `path`, `team`, `identifier`, `signer`) once, on any thread,
/// to ask the user; answers come back through `desktop_tools_set_callers`. Agent input aimed at this host's own
/// processes, or sent while one of them shows a prompt or menu, is refused too. Pass NULL to turn it off.
@_cdecl("desktop_tools_set_caller_handler")
public func setCallerHandler(_ handler: (@convention(c) (UnsafePointer<CChar>) -> Void)?) {
	guard let handler else { return Callers.shared.setHandler(nil) }
	// A C function pointer captures nothing, so calling it from any thread is safe.
	nonisolated(unsafe) let ask = handler
	Callers.shared.setHandler { caller in
		guard let data = try? JSONEncoder().encode(caller) else { return }
		String(decoding: data, as: UTF8.self).withCString { ask($0) }
	}
}

/// Sets every answer so far, as the JSON array the app keeps in `callers.json`: `{caller, allowed, decided}`.
@_cdecl("desktop_tools_set_callers")
public func setCallers(_ json: UnsafePointer<CChar>) {
	let data = Data(String(cString: json).utf8)
	Callers.shared.setDecisions((try? JSONDecoder().decode([CallerDecision].self, from: data)) ?? [])
}

/// Returns the recent operations as a JSON array, newest first; release it with `desktop_tools_free`.
/// They are kept in memory only and never include typed text, clipboard contents or values.
@_cdecl("desktop_tools_activity")
public func activity() -> UnsafeMutablePointer<CChar>? {
	let data = try! JSONEncoder().encode(Activity.shared.read())
	return strdup(String(decoding: data, as: UTF8.self))
}

/// Appends each listed operation to `path`, created readable only by the user, one line each, newest last. Past
/// 1 MiB the file moves to `<path>.1`. Pass NULL to stop.
@_cdecl("desktop_tools_set_log")
public func setLog(_ path: UnsafePointer<CChar>?) {
	ActivityLog.shared.open(path.map { String(cString: $0) })
}

/// Appends one line of the embedding app's own to the log, such as when it starts or the user pauses input.
@_cdecl("desktop_tools_log")
public func log(_ message: UnsafePointer<CChar>) {
	ActivityLog.shared.write(String(cString: message))
}

@_cdecl("desktop_tools_free")
public func release(_ value: UnsafeMutableRawPointer?) {
	free(value)
}

/// Requests `accessibility`, `screenRecording`, or `eventSynthesizing` for this process.
@_cdecl("desktop_tools_permission")
public func permission(_ kind: UnsafePointer<CChar>) {
	let kind = String(cString: kind)
	DispatchQueue.main.async {
		switch kind {
		case "accessibility":
			// The C SDK exposes this immutable option key as an unisolated mutable global.
			let options = ["AXTrustedCheckOptionPrompt": true]
			_ = AXIsProcessTrustedWithOptions(options as CFDictionary)
		case "screenRecording":
			_ = CGRequestScreenCaptureAccess()
		case "eventSynthesizing":
			// macOS caches preflight results; keep an interactive grant, as Peekaboo's permission state did.
			state.recordEventSynthesizing(CGRequestPostEventAccess())
		default:
			break
		}
	}
}

private struct ClipboardPolicy: Encodable {
	var policy = "unknown"
	var readAdmitted = false
	var policyAvailable = false

	static func current() -> ClipboardPolicy {
		guard #available(macOS 15.4, *) else {
			return .init(policy: "unavailable_on_this_os", readAdmitted: true, policyAvailable: false)
		}
		let policy: String
		switch NSPasteboard.general.accessBehavior {
		case .default: policy = "default"
		case .ask: policy = "ask"
		case .alwaysAllow: policy = "always_allow"
		case .alwaysDeny: policy = "always_deny"
		@unknown default: policy = "unknown"
		}
		return .init(policy: policy, readAdmitted: policy == "always_allow", policyAvailable: true)
	}
}
