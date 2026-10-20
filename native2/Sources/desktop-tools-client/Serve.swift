import DesktopProtocol
import Foundation

/// --serve: forwards each request line to the host under its own id and writes each reply as it arrives, so calls
/// overlap as they do through the MCP server. Exits once stdin closes and every call has replied, or when the
/// connection fails, after ending the calls still waiting.
func serve(_ connection: Connection) -> Never {
	let calls = Calls()
	Thread.detachNewThread {
		do {
			while true {
				let frame = try connection.receive()
				guard let id = frame["id"]?.int, calls.finish(id) else { continue }
				if let result = frame["result"] {
					calls.emit(.object([("id", JSON(id)), ("result", result)]))
				} else {
					calls.emit(failure(JSON(id), "DESKTOP_ERROR", frame["error"]?.string ?? "The host replied without a result."))
				}
			}
		} catch {
			// The calls may have reached the host, so they aren't refusals: the caller reports them as errors.
			calls.drop("The connection to the host failed: \(error).")
		}
	}

	while let line = readLine() {
		guard !line.allSatisfy(\.isWhitespace) else { continue }
		guard let request = try? JSON(parsing: Data(line.utf8)), request.pairs != nil else {
			calls.emit(failure(.null, "USAGE", "Each request must be one JSON object on its own line."))
			continue
		}
		if let id = request["cancel"]?.int {
			try? connection.send(.object([("cancel", JSON(id))]))
			continue
		}
		guard let id = request["id"]?.int, let tool = request["tool"]?.string else {
			calls.emit(failure(request["id"] ?? .null, "USAGE", "A request needs an integer id and a tool."))
			continue
		}
		let toolArguments = request["arguments"] ?? .object([])
		guard toolArguments.pairs != nil else {
			calls.emit(failure(JSON(id), "USAGE", "A request's arguments must be one JSON object."))
			continue
		}
		guard calls.start(id) else {
			calls.emit(failure(JSON(id), "USAGE", "Request \(id) is still running."))
			continue
		}
		var frame: [(String, JSON)] = [("id", JSON(id)), ("tool", JSON(tool)), ("arguments", toolArguments)]
		if request["verbose"] == .bool(true) { frame.append(("verbose", true)) }
		// A failed send means the connection is gone; the reader ends this call with the others.
		try? connection.send(.object(frame))
	}
	calls.drain()
	exit(0)
}

func failure(_ id: JSON, _ code: String, _ message: String) -> JSON {
	.object([("id", id), ("error", .object([("code", JSON(code)), ("message", JSON(message))]))])
}

/// The calls sent and not yet answered; output lines are written under the same lock, so they never interleave.
final class Calls: @unchecked Sendable {
	private let state = NSCondition()
	private var pending: Set<Int> = []

	func emit(_ value: JSON) {
		state.lock()
		defer { state.unlock() }
		FileHandle.standardOutput.write(Data((value.text + "\n").utf8))
	}

	func start(_ id: Int) -> Bool {
		state.lock()
		defer { state.unlock() }
		return pending.insert(id).inserted
	}

	/// Whether the id was waiting; a reply to anything else is dropped.
	func finish(_ id: Int) -> Bool {
		state.lock()
		defer { state.broadcast(); state.unlock() }
		return pending.remove(id) != nil
	}

	/// Ends every waiting call with `message`, then exits.
	func drop(_ message: String) -> Never {
		state.lock()
		for id in pending.sorted() {
			FileHandle.standardOutput.write(Data((failure(JSON(id), "DESKTOP_ERROR", message).text + "\n").utf8))
		}
		exit(1)
	}

	func drain() {
		state.lock()
		while !pending.isEmpty { state.wait() }
		state.unlock()
	}
}
