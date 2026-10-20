import DesktopCore
import DesktopProtocol
import Foundation

/// Serves tool calls on a Unix socket to MCP binaries of the same user, one connection each, kept open.
public final class Server: @unchecked Sendable {
	public let path: String
	private var listener: Int32 = -1

	public init(path: String) { self.path = path }

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
		guard listen(fd, 16) == 0 else { throw WireError.system("listen", errno) }
		listener = fd
		Thread.detachNewThread { [self] in accept() }
	}

	private func accept() {
		while true {
			let fd = Darwin.accept(listener, nil, nil)
			if fd < 0 {
				if errno == EINTR { continue }
				return
			}
			// TODO(#143): check the peer's signing identity as DesktopToolsCallers does; same-user only for now.
			var uid: uid_t = 0
			var gid: gid_t = 0
			guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
				close(fd)
				continue
			}
			let connection = Connection(fd: fd)
			Thread.detachNewThread { Session(connection).serve() }
		}
	}
}

/// One MCP binary's connection: requests run as tasks, and a cancel frame cancels its task.
private final class Session: @unchecked Sendable {
	let connection: Connection
	private let lock = NSLock()
	private var running: [Int: Task<Void, Never>] = [:]

	init(_ connection: Connection) { self.connection = connection }

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
					let result = await Tools.call(frame["tool"]?.string ?? "", arguments: frame["arguments"] ?? .object([]))
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
