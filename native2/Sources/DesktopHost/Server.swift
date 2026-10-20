import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

/// Another host holds the socket's lease, as one that is still quitting does until its calls finish.
public struct SocketOwned: LocalizedError {
	public let path: String
	public var errorDescription: String? { "Another host is serving \(path)." }
}

/// The lease file isn't a plain file of this user, so it could be a link planted to lock something else.
public struct UnsafeLease: LocalizedError {
	public let path: String
	public var errorDescription: String? { "\(path) isn't a plain file owned by this user, so it can't hold the socket's lease." }
}

/// Serves tool calls on a Unix socket to MCP binaries of the same user, one connection each, kept open.
///
/// Like Peekaboo's Bridge host, it holds an exclusive lock on `<socket>.lock` from start until its last call finishes
/// after stop, so a second host can't take the path while this one serves, and a new one starts only once this one
/// has drained.
public final class Server: @unchecked Sendable {
	public let path: String
	private var listener: Int32 = -1
	private let lock = NSLock()
	private var stopped = false
	private var lease: Int32 = -1
	/// Calls running on any connection, which stop waits for before it gives up the lease.
	private var active = 0
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
		let held = try Self.acquireLease(path)
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		do {
			guard fd >= 0 else { throw WireError.system("socket", errno) }
			// Holding the lease, any socket left at the path belongs to a host that has exited.
			unlink(path)
			var address = try unixAddress(path)
			let bound = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
			}
			guard bound == 0 else { throw WireError.system("bind", errno) }
			chmod(path, 0o600)
			lstat(path, &published)
			guard listen(fd, 16) == 0 else { throw WireError.system("listen", errno) }
		} catch {
			if fd >= 0 { close(fd) }
			flock(held, LOCK_UN)
			close(held)
			throw error
		}
		listener = fd
		lease = held
		Thread.detachNewThread { [self] in accept() }
	}

	private static func acquireLease(_ path: String) throws -> Int32 {
		let leasePath = path + ".lock"
		let fd = open(leasePath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
		guard fd >= 0 else { throw errno == ELOOP ? UnsafeLease(path: leasePath) : WireError.system("open lease", errno) }
		var info = stat()
		guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else {
			close(fd)
			throw UnsafeLease(path: leasePath)
		}
		guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
			let code = errno
			close(fd)
			throw code == EWOULDBLOCK ? SocketOwned(path: path) : WireError.system("lock lease", code)
		}
		return fd
	}

	/// Stops accepting connections and calls, and removes the socket when the path still names it. Calls already
	/// running finish; the lease goes with the last of them.
	public func stop() {
		let first = lock.withLock { defer { stopped = true }; return !stopped }
		guard first, listener >= 0 else { return }
		var now = stat()
		if lstat(path, &now) == 0, now.st_dev == published.st_dev, now.st_ino == published.st_ino { unlink(path) }
		lock.withLock { if active == 0 { releaseLease() } }
	}

	/// Waits until the calls running at stop have finished, at most `seconds`, then gives up the lease regardless.
	public func drained(within seconds: Double = 30) async {
		let deadline = ContinuousClock.now + .seconds(seconds)
		while lock.withLock({ lease >= 0 }), ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(50))
		}
		lock.withLock { releaseLease() }
	}

	/// Counts a call in, or refuses it once the server has stopped.
	func begin() -> Bool {
		lock.withLock {
			guard !stopped else { return false }
			active += 1
			return true
		}
	}

	func end() {
		lock.withLock {
			active -= 1
			if stopped, active == 0 { releaseLease() }
		}
	}

	/// Called with `lock` held.
	private func releaseLease() {
		guard lease >= 0 else { return }
		flock(lease, LOCK_UN)
		close(lease)
		lease = -1
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
			Thread.detachNewThread { [self] in Session(connection, client: peer.pid, server: self).serve() }
		}
	}
}

/// One MCP binary's connection: requests run as tasks, and a cancel frame cancels its task.
private final class Session: @unchecked Sendable {
	let connection: Connection
	let client: pid_t
	let server: Server
	private let lock = NSLock()
	private var running: [Int: Task<Void, Never>] = [:]

	init(_ connection: Connection, client: pid_t, server: Server) {
		self.connection = connection
		self.client = client
		self.server = server
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
				guard server.begin() else {
					try connection.send(.object([("id", JSON(id)), ("error", "The Desktop Tools host is stopping, so nothing ran.")]))
					continue
				}
				let task = Task { [self] in
					defer { server.end() }
					let result = await Tools.observed(
						frame["tool"]?.string ?? "", arguments: frame["arguments"] ?? .object([]), client: client,
						verbose: frame["verbose"] == .bool(true)
					)
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
