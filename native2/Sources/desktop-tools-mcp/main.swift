import DesktopProtocol
import Foundation

// MCP over stdio. It only translates: every tool call goes to the host app over one open connection,
// because the host is what holds the macOS permissions.

let arguments = CommandLine.arguments.dropFirst()
let state = defaultStateFolder()
let socketPath = arguments.firstIndex(of: "--socket").flatMap { arguments.dropFirst($0 - arguments.startIndex + 1).first }
	?? (state as NSString).appendingPathComponent("desktop.sock")
let serverVersion = "0.0.0-spike"

// Newest first; an unsupported client version gets the newest, as the MCP lifecycle requires.
let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

// The host labels the window in use with the agent's name; unknown clients show as "Agent".
let agents: [(String, String)] = [("claude", "Claude"), ("codex", "Codex"), ("cursor", "Cursor"), ("gemini", "Gemini"), ("copilot", "Copilot")]
func agentName(_ info: JSON?) -> String? {
	if let name = info?["name"]?.string?.lowercased(), let known = agents.first(where: { name.contains($0.0) }) {
		return known.1
	}
	guard let title = info?["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
	return String(title.prefix(40))
}

let tools: JSON = .array((Contract.tools.array ?? []).map { tool in
	.object([
		("name", tool["name"] ?? .null),
		("description", tool["description"] ?? .null),
		("inputSchema", tool["inputSchema"] ?? .null),
		("annotations", tool["annotations"] ?? .null),
	])
})

let output = NSLock()
func send(_ value: JSON) {
	output.lock()
	defer { output.unlock() }
	FileHandle.standardOutput.write(Data((value.text + "\n").utf8))
}
func fail(_ id: JSON, _ code: Int, _ message: String) {
	send(.object([("jsonrpc", "2.0"), ("id", id), ("error", .object([("code", JSON(code)), ("message", JSON(message))]))]))
}
func errorResult(_ text: String) -> JSON {
	.object([("content", [.object([("type", "text"), ("text", JSON(text))])]), ("isError", true)])
}

/// The connection to the host, opened on first use and again after it drops.
actor Host {
	private var connection: Connection?
	private var next = 1
	private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]

	private func connected() throws -> Connection {
		if let connection { return connection }
		let connection = try Connection.connect(to: socketPath)
		try connection.send(.object([("hello", JSON(wireVersion))]))
		guard try connection.receive()["hello"]?.int == wireVersion else {
			throw WireError.system("hello", EPROTO)
		}
		self.connection = connection
		Thread.detachNewThread { [connection] in
			while true {
				do {
					let frame = try connection.receive()
					Task { await self.deliver(frame) }
				} catch {
					Task { await self.dropped(connection, error) }
					return
				}
			}
		}
		return connection
	}

	private func deliver(_ frame: JSON) {
		guard let id = frame["id"]?.int, let waiting = pending.removeValue(forKey: id) else { return }
		if let result = frame["result"] {
			waiting.resume(returning: result)
		} else {
			waiting.resume(throwing: HostFailure(message: frame["error"]?.string ?? "The host replied without a result."))
		}
	}

	private func dropped(_ connection: Connection, _ error: Error) {
		guard self.connection === connection else { return }
		self.connection = nil
		for waiting in pending.values { waiting.resume(throwing: error) }
		pending.removeAll()
	}

	/// Sends one request and returns its reply's result. `started` gets the host-side ID for cancellation.
	func request(_ body: [(String, JSON)], started: @Sendable (Int) -> Void = { _ in }) async throws -> JSON {
		let connection = try connected()
		let id = next
		next += 1
		started(id)
		return try await withCheckedThrowingContinuation { continuation in
			pending[id] = continuation
			do {
				try connection.send(.object([("id", JSON(id))] + body))
			} catch {
				pending.removeValue(forKey: id)
				continuation.resume(throwing: error)
			}
		}
	}

	func cancel(_ id: Int) {
		try? connection?.send(.object([("cancel", JSON(id))]))
	}
}

struct HostFailure: Error, CustomStringConvertible { let message: String; var description: String { message } }

let host = Host()
let session = Session()

/// Request bookkeeping: the agent's name, cancellations, and the one-at-a-time queue for actions.
actor Session {
	var agent: String?
	private var hostIDs: [String: Int] = [:]
	private var cancelled: Set<String> = []
	private var actions: Task<Void, Never>?
	private var inFlight: [Int: Task<Void, Never>] = [:]
	private var nextTask = 0

	/// Keeps a call's task until it finishes, so stdin closing doesn't drop its response.
	func track(_ task: Task<Void, Never>) {
		let key = nextTask
		nextTask += 1
		inFlight[key] = task
		Task { await task.value; self.untrack(key) }
	}

	private func untrack(_ key: Int) { inFlight.removeValue(forKey: key) }

	func drain() async {
		while let task = inFlight.values.first { await task.value; await Task.yield() }
	}

	func setAgent(_ name: String?) { agent = name }

	func started(_ key: String, _ id: Int) {
		hostIDs[key] = id
		if cancelled.contains(key) { Task { await host.cancel(id) } }
	}

	func cancel(_ key: String) async {
		cancelled.insert(key)
		if let id = hostIDs[key] { await host.cancel(id) }
	}

	/// Whether the request was cancelled; forgets it either way.
	func finish(_ key: String) -> Bool {
		hostIDs.removeValue(forKey: key)
		return cancelled.remove(key) != nil
	}

	// Actions run one at a time; each input depends on the state the previous one left.
	func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
		let previous = actions
		let task = Task { await previous?.value; await work() }
		actions = task
		return task
	}
}

func call(_ key: String, tool: String, arguments: JSON) async -> JSON {
	do {
		let agent = await session.agent
		return try await host.request(
			[("tool", JSON(tool)), ("arguments", arguments), ("agent", JSON(agent))],
			started: { id in Task { await session.started(key, id) } }
		)
	} catch let error as WireError {
		if case .system("connect", _) = error {
			return errorResult("The Desktop Tools 2 host isn't serving at \(socketPath). Start it with: native2/.build/debug/desktop-tools-host")
		}
		return errorResult(error.description)
	} catch {
		return errorResult(String(describing: error))
	}
}

func handle(_ message: JSON) async {
	// This server sends no requests, so a message without a method is a stray response.
	guard let method = message["method"]?.string else { return }
	let params = message["params"] ?? .object([])
	guard let id = message["id"], !id.isNull else {
		if method == "notifications/cancelled", let request = params["requestId"] {
			await session.cancel(request.text)
		}
		return
	}
	switch method {
	case "initialize":
		let requested = params["protocolVersion"]?.string ?? ""
		await session.setAgent(agentName(params["clientInfo"]))
		send(.object([("jsonrpc", "2.0"), ("id", id), ("result", .object([
			("protocolVersion", JSON(versions.contains(requested) ? requested : versions[0])),
			("capabilities", .object([("tools", .object([]))])),
			("serverInfo", .object([("name", "desktop-tools"), ("version", JSON(serverVersion))])),
			("instructions", JSON(Contract.instructions)),
		]))]))
	case "ping":
		send(.object([("jsonrpc", "2.0"), ("id", id), ("result", .object([]))]))
	case "tools/list":
		send(.object([("jsonrpc", "2.0"), ("id", id), ("result", .object([("tools", tools)]))]))
	case "tools/call":
		guard let name = params["name"]?.string, Contract.names.contains(name) else {
			return fail(id, -32602, "Unknown tool: \(params["name"]?.string ?? "undefined")")
		}
		let arguments = params["arguments"] ?? .object([])
		let key = id.text
		let respond: @Sendable () async -> Void = {
			let result = await call(key, tool: name, arguments: arguments)
			// A cancelled request gets no response.
			if await !session.finish(key) { send(.object([("jsonrpc", "2.0"), ("id", id), ("result", result)])) }
		}
		// Queue actions in arrival order; reads run alongside them.
		if Contract.actions.contains(name) {
			await session.track(session.enqueue(respond))
		} else {
			await session.track(Task { await respond() })
		}
	default:
		fail(id, -32601, "Method not found: \(method)")
	}
}

for try await line in FileHandle.standardInput.bytes.lines {
	guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
	guard let message = try? JSON(parsing: line) else {
		fail(.null, -32700, "Parse error")
		continue
	}
	guard case .object = message else {
		fail(.null, -32600, "Invalid request")
		continue
	}
	await handle(message)
}
// Finish the calls already made once the client closes stdin.
await session.drain()
