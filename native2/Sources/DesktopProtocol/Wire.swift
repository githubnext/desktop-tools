import Darwin
import Foundation

/// The MCP binary and the host speak length-prefixed JSON frames over one long-lived Unix socket.
///
/// Requests: `{"id", "tool", "arguments", "agent"?}`, `{"id", "ping": true}` or `{"cancel": id}`.
/// Replies: `{"id", "result"}` with an MCP tool result, or `{"id", "error"}` with a message.
/// The first frame each way is `{"hello": wireVersion}`; a mismatch closes the connection.
public let wireVersion = 1
/// Bounds one frame; inspection images stay well under it.
public let maxFrame = 64 * 1024 * 1024

public enum WireError: Error, CustomStringConvertible {
	case closed
	case tooLarge(Int)
	case system(String, Int32)

	public var description: String {
		switch self {
		case .closed: "The Desktop Tools host closed the connection."
		case let .tooLarge(n): "A frame of \(n) bytes exceeds the limit."
		case let .system(call, code): "\(call) failed: \(String(cString: strerror(code)))."
		}
	}
}

/// One socket. Reads come from a single reader; writes are serialized here.
public final class Connection: @unchecked Sendable {
	public let fd: Int32
	private let writing = NSLock()

	public init(fd: Int32) {
		self.fd = fd
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
	}

	deinit { close(fd) }

	public static func connect(to path: String) throws -> Connection {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { throw WireError.system("socket", errno) }
		var address = try unixAddress(path)
		let result = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard result == 0 else {
			let code = errno
			close(fd)
			throw WireError.system("connect", code)
		}
		return Connection(fd: fd)
	}

	public func send(_ value: JSON) throws {
		let body = Array(value.text.utf8)
		guard body.count <= maxFrame else { throw WireError.tooLarge(body.count) }
		var length = UInt32(body.count).bigEndian
		var frame = [UInt8](repeating: 0, count: 4)
		withUnsafeBytes(of: &length) { frame.replaceSubrange(0..<4, with: $0) }
		frame += body
		writing.lock()
		defer { writing.unlock() }
		try frame.withUnsafeBytes { buffer in
			var sent = 0
			while sent < buffer.count {
				let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
				if n < 0, errno == EINTR { continue }
				guard n > 0 else { throw WireError.system("write", errno) }
				sent += n
			}
		}
	}

	/// Blocks until a whole frame arrives.
	public func receive() throws -> JSON {
		let header = try read(4)
		let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
		guard length <= maxFrame else { throw WireError.tooLarge(length) }
		return try JSON(parsing: Data(try read(length)))
	}

	private func read(_ count: Int) throws -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: count)
		var got = 0
		while got < count {
			let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
			if n < 0, errno == EINTR { continue }
			guard n > 0 else { throw n == 0 ? WireError.closed : WireError.system("read", errno) }
			got += n
		}
		return bytes
	}

	/// Closes both directions, which wakes a reader blocked in `receive`.
	public func shutdown() { Darwin.shutdown(fd, SHUT_RDWR) }
}

public func unixAddress(_ path: String) throws -> sockaddr_un {
	var address = sockaddr_un()
	address.sun_family = sa_family_t(AF_UNIX)
	let bytes = Array(path.utf8)
	guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw WireError.system("socket path", ENAMETOOLONG) }
	withUnsafeMutableBytes(of: &address.sun_path) { buffer in
		buffer.copyBytes(from: bytes)
	}
	return address
}

/// The spike's own state folder, so it runs beside the installed app without touching its socket.
public func defaultStateFolder() -> String {
	ProcessInfo.processInfo.environment["DESKTOP_TOOLS2_STATE"]
		?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/desktop-tools2")
}
