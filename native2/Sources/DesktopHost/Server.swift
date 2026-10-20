import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

/// Serves tool calls on a Unix socket to MCP binaries of the same user, one connection each, kept open.
public final class Server: @unchecked Sendable {
	public let path: String
	private var listener: Int32 = -1
	private let lock = NSLock()
	private var stopped = false
	/// The socket file this server bound, which stop removes only while the path still names it.
	private var published = stat()

	/// The signature a client must carry; nil serves any process of this user, as an unsigned dev host must.
	public let client: ClientRequirement?

	public init(path: String, client: ClientRequirement? = nil) {
		self.path = path
		self.client = client
	}

	public func start() throws {
		try FileManager.default.createDirectory(
			atPath: (path as NSString).deletingLastPathComponent,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		unlink(path)
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw WireError.system("socket", errno) }
		var address = try unixAddress(path)
		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
		guard bound == 0 else { throw WireError.system("bind", errno) }
		chmod(path, 0o600)
		lstat(path, &published)
		guard listen(fd, 16) == 0 else { throw WireError.system("listen", errno) }
		listener = fd
		Thread.detachNewThread { [self] in accept() }
	}

	/// Stops accepting and removes the socket when the path still names it; open connections finish on their own.
	public func stop() {
		let first = lock.withLock { defer { stopped = true }; return !stopped }
		guard first, listener >= 0 else { return }
		var now = stat()
		if lstat(path, &now) == 0, now.st_dev == published.st_dev, now.st_ino == published.st_ino { unlink(path) }
	}

	private func accept() {
		// A blocked accept doesn't wake when another thread closes its socket, so it polls for stop.
		var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
		while true {
			if lock.withLock({ stopped }) {
				close(listener)
				return
			}
			guard poll(&ready, 1, 250) > 0 else { continue }
			let fd = Darwin.accept(listener, nil, nil)
			if fd < 0 {
				if errno == EINTR { continue }
				return
			}
			// Only the exact signed client of this user, checked by the audit token so a reused pid can't pass.
			guard let peer = try? Peer(socket: fd), peer.userID == geteuid(), client.map(peer.satisfies) ?? true else {
				close(fd)
				continue
			}
			let connection = Connection(fd: fd)
			Thread.detachNewThread { Session(connection, client: peer.pid).serve() }
		}
	}
}

/// One MCP binary's connection: requests run as tasks, and a cancel frame cancels its task.
private final class Session: @unchecked Sendable {
	let connection: Connection
	let client: pid_t
	private let lock = NSLock()
	private var running: [Int: Task<Void, Never>] = [:]

	init(_ connection: Connection, client: pid_t) {
		self.connection = connection
		self.client = client
	}

	func serve() {
		do {
			guard try connection.receive()["hello"]?.int == wireVersion else { return }
			try connection.send(.object([("hello", JSON(wireVersion))]))
			while true {
				let frame = try connection.receive()
				if let id = frame["cancel"]?.int {
					lock.withLock { running[id] }?.cancel()
					continue
				}
				guard let id = frame["id"]?.int else { continue }
				let task = Task { [self] in
					let result = await Tools.observed(frame["tool"]?.string ?? "", arguments: frame["arguments"] ?? .object([]), client: client)
					lock.withLock { _ = running.removeValue(forKey: id) }
					try? connection.send(.object([("id", JSON(id)), ("result", result.mcp)]))
				}
				lock.withLock { running[id] = task }
			}
		} catch {
			for task in lock.withLock({ Array(running.values) }) { task.cancel() }
		}
	}
}
