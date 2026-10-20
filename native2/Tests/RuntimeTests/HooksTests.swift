import DesktopCore
@testable import DesktopHost
import Foundation
import Testing

struct HooksTests {
	@Test
	func `input sent but not read back is recorded as unknown, as the Bridge recorded it`() {
		func action(_ state: String) -> ToolResult {
			ToolResult(text: #"{"action":{"outcome":"completed","native_outcome":{"state":"\#(state)"}}}"#, outcome: "completed")
		}
		#expect(Hooks.outcome(action("confirmed_change")) == .completed)
		#expect(Hooks.outcome(action("confirmed_no_change")) == .completed)
		#expect(Hooks.outcome(action("dispatched_unverified")) == .unknown)
		#expect(Hooks.outcome(ToolResult(text: "{}", outcome: "refused", isError: true)) == .refused)
		#expect(Hooks.outcome(ToolResult(text: "{}", outcome: "unknown", isError: true)) == .unknown)
		#expect(Hooks.outcome(ToolResult(text: "{}")) == .completed)
		#expect(Hooks.outcome(ToolResult(text: "bad pid", isError: true)) == .error)
	}

	@Test
	func `a call's window comes from its snapshot, its target, or its pid and window`() async {
		#expect(await Hooks.target(.object([("pid", 12), ("window", 34)])) == (12, 34))
		#expect(await Hooks.target(.object([("target", .object([("pid", 5), ("window_id", 6)]))])) == (5, 6))
		#expect(await Hooks.target(.object([("target", .object([("pid", 5)]))])) == (5, nil))
		#expect(await Hooks.target(.object([("snapshot", "missing")])) == (nil, nil))
	}

	@Test
	func `each call is reported once it finishes, with the window it named`() async {
		let seen = Seen()
		Hooks.operation = { seen.add($0) }
		defer { Hooks.operation = nil }
		_ = await Tools.observed("desktop_windows", arguments: .object([("pid", 1)]), client: getpid())
		let operation = seen.all.first { $0.tool == "desktop_windows" }
		#expect(operation?.outcome == .error)
		#expect(operation?.mutatesDesktop == false)
		#expect(operation?.targetProcess == 1)
		#expect(operation?.targetWindow == nil)
	}

	@Test
	func `stopping the server removes its socket and stops accepting`() throws {
		let path = NSTemporaryDirectory() + "dt2-runtime-\(getpid()).sock"
		let server = Server(path: path)
		try server.start()
		var info = stat()
		#expect(lstat(path, &info) == 0)
		server.stop()
		#expect(lstat(path, &info) != 0)
		Thread.sleep(forTimeInterval: 0.4)
	}

	@Test
	func `a second host can't take the socket until the first has stopped and drained`() async throws {
		let path = NSTemporaryDirectory() + "dt2-lease-\(getpid()).sock"
		let first = Server(path: path)
		try first.start()
		#expect(throws: SocketOwned.self) { try Server(path: path).start() }

		// A call still running at stop keeps the lease, and no new call starts.
		#expect(first.begin())
		first.stop()
		#expect(!first.begin())
		#expect(throws: SocketOwned.self) { try Server(path: path).start() }

		first.end()
		let second = Server(path: path)
		try second.start()
		second.stop()
		await second.drained()
		try await Task.sleep(for: .milliseconds(400))
	}

	@Test
	func `drained gives up the lease after its limit even with a call still running`() async throws {
		let path = NSTemporaryDirectory() + "dt2-drain-\(getpid()).sock"
		let server = Server(path: path)
		try server.start()
		#expect(server.begin())
		server.stop()
		await server.drained(within: 0.2)
		let next = Server(path: path)
		try next.start()
		next.stop()
		server.end()
		try await Task.sleep(for: .milliseconds(400))
	}
}

private final class Seen: @unchecked Sendable {
	private let lock = NSLock()
	private var list: [Hooks.Operation] = []
	func add(_ operation: Hooks.Operation) { lock.withLock { list.append(operation) } }
	var all: [Hooks.Operation] { lock.withLock { list } }
}
