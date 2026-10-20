import AppKit
import Darwin
import Foundation

// Ported from native/'s client host.swift: what `desktop-client status` and `repair` find and do, and how the
// client and MCP server bundled in the app find its socket and open it.

/// How long to wait for the host after opening its app: a fresh launch serves in about a second, and a host that
/// waits for a quitting one to release the socket retries after 1, 2 and 4 seconds.
public let repairWait: TimeInterval = 10

/// Whether anything accepts connections on a socket path, found by connecting without sending a request.
public enum Reach: String, Encodable, Sendable {
	/// A host accepted the connection.
	case serving
	/// The path is there, but nothing listens on it: a host that stopped or died left it behind.
	case refused
	/// Nothing is at the path: no host published it, or something removed it.
	case missing

	public static func probe(_ path: String) -> Reach {
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(path.utf8CString)
		guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return .missing }
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return .refused }
		defer { close(fd) }
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		if connected == 0 { return .serving }
		return errno == ENOENT ? .missing : .refused
	}
}

/// The app this client ships in, which hosts its socket: opening it starts the host, or makes a running one check
/// its socket again.
public struct HostApp: Sendable {
	public let url: URL
	public let identifier: String
	public let name: String

	/// The app bundle around this client's executable, following the link the app keeps in its state folder.
	public static func containing() -> HostApp? {
		guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
		// <App>.app/Contents/MacOS/desktop-tools-client
		let url = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		guard url.pathExtension == "app", let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier
		else { return nil }
		let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
			?? url.deletingPathExtension().lastPathComponent
		return HostApp(url: url, identifier: identifier, name: name)
	}

	/// The app's state folder, which holds its socket: DESKTOP_TOOLS_STATE, or a folder of its own for a development
	/// build, as the app chooses it.
	public var stateFolder: String {
		if let state = ProcessInfo.processInfo.environment["DESKTOP_TOOLS_STATE"], !state.isEmpty { return state }
		let name = identifier.hasSuffix(".dev") ? "desktop-tools-dev" : "desktop-tools"
		return (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/\(name)")
	}

	public var running: NSRunningApplication? {
		NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first { !$0.isTerminated }
	}

	/// Starts the app in the background, or opens a running one again, which makes it check its socket.
	public func open() {
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = false
		configuration.addsToRecentItems = false
		configuration.promptsUserIfNeeded = false
		let done = DispatchSemaphore(value: 0)
		NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
		_ = done.wait(timeout: .now() + repairWait)
	}
}

/// What `desktop-client status` and `repair` print.
public struct HostReport: Encodable, Sendable {
	public let socket: String
	public let reach: Reach
	public let app: String?
	public let bundle_id: String?
	public let app_path: String?
	public let running: Bool
	public let pid: Int32?
	/// Set by repair: whether it opened the app, and how long it waited.
	public var opened: Bool?
	public var waited_ms: Int?

	public init(socket: String, host: HostApp?) {
		self.socket = socket
		reach = Reach.probe(socket)
		app = host?.name
		bundle_id = host?.identifier
		app_path = host?.url.path
		let running = host?.running
		self.running = running != nil
		pid = running?.processIdentifier
	}

	/// Why nothing serves the socket, as `HOST_NOT_RUNNING` or `HOST_NOT_SERVING`.
	public var failure: (code: String, message: String) {
		let name = app ?? "The desktop host app"
		if !running {
			let tried = opened == true ? ", and opening it didn't start it serving within \(Int(repairWait)) s" : ""
			return ("HOST_NOT_RUNNING", "\(name) isn't running\(tried), so nothing ran. Ask the user to open it.")
		}
		let pid = pid.map { " (pid \($0))" } ?? ""
		let tried = opened == true ? ", and opening it again didn't fix that within \(Int(repairWait)) s" : ""
		return ("HOST_NOT_SERVING", "\(name)\(pid) is running but isn't serving \(socket)\(tried), so nothing ran. "
			+ "Ask the user to check the status line in its menu, or to quit and reopen it.")
	}
}

public enum HostRepair {
	public static func status(_ socket: String) -> HostReport {
		HostReport(socket: socket, host: HostApp.containing())
	}

	/// Makes the host serve `socket` if it doesn't: opens its app, which starts it or makes a running one publish
	/// its socket again, then waits for the socket to accept a connection. Nothing is sent but a bare connect, so
	/// a repair never repeats an operation.
	public static func repair(_ socket: String) -> HostReport {
		let host = HostApp.containing()
		var report = HostReport(socket: socket, host: host)
		guard report.reach != .serving, let host else { return report }
		let started = Date()
		host.open()
		while Reach.probe(socket) != .serving, Date().timeIntervalSince(started) < repairWait {
			Thread.sleep(forTimeInterval: 0.2)
		}
		report = HostReport(socket: socket, host: host)
		report.opened = true
		report.waited_ms = Int(Date().timeIntervalSince(started) * 1000)
		return report
	}
}
