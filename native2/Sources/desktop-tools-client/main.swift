import AppKit
import DesktopProtocol
import Foundation

// One tool call per run, for embedders that spawn a client per request, as createDesktop does with wire 2:
//
//   desktop-tools-client <socket> <tool> [--verbose]   with the tool's arguments as a JSON object on stdin
//
// It prints one JSON line: {"result": <MCP tool result>}, or {"error": {"code", "message"}} and exits 1 when nothing
// ran. DESKTOP_TOOLS_AGENT in its environment names the agent in the host's window outline, as native/'s client does.

/// How long to wait for the host after opening its app: a fresh launch serves in about a second, and a host that
/// waits for a quitting one to release the socket retries after 1, 2 and 4 seconds.
let repairWait: TimeInterval = 10

func finish(_ value: JSON, status: Int32) -> Never {
	FileHandle.standardOutput.write(Data((value.text + "\n").utf8))
	exit(status)
}

func refuse(_ code: String, _ message: String) -> Never {
	finish(.object([("error", .object([("code", JSON(code)), ("message", JSON(message))]))]), status: 1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let positional = arguments.filter { !$0.hasPrefix("--") }
guard positional.count == 2 else {
	refuse("USAGE", "Usage: desktop-tools-client <socket> <tool> [--verbose], with the tool's arguments as JSON on stdin.")
}
let (socketPath, tool) = (positional[0], positional[1])
let verbose = arguments.contains("--verbose")

let input = FileHandle.standardInput.readDataToEndOfFile()
let toolArguments: JSON
if input.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
	toolArguments = .object([])
} else if let parsed = try? JSON(parsing: input), parsed.pairs != nil {
	toolArguments = parsed
} else {
	refuse("USAGE", "The tool's arguments on stdin must be one JSON object.")
}

/// The app bundle around this executable, which hosts the socket: <App>.app/Contents/MacOS/desktop-tools-client.
func containingApp() -> URL? {
	guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
	let url = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
	return url.pathExtension == "app" ? url : nil
}

/// Starts the app in the background, or opens a running one again, which makes it check its socket.
func open(_ app: URL) {
	let configuration = NSWorkspace.OpenConfiguration()
	configuration.activates = false
	configuration.addsToRecentItems = false
	configuration.promptsUserIfNeeded = false
	let done = DispatchSemaphore(value: 0)
	NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in done.signal() }
	_ = done.wait(timeout: .now() + repairWait)
}

/// Connects and exchanges hellos; nil with the connect errno when no host accepted.
func connect() throws -> (Connection?, Int32) {
	do {
		let connection = try Connection.connect(to: socketPath)
		try connection.send(.object([("hello", JSON(wireVersion))]))
		guard try connection.receive()["hello"]?.int == wireVersion else {
			refuse("DESKTOP_ERROR", "The host at \(socketPath) speaks another wire version.")
		}
		return (connection, 0)
	} catch let WireError.system("connect", code) {
		return (nil, code)
	}
}

var (connection, failure) = try connect()
if connection == nil, let app = containingApp() {
	open(app)
	let deadline = Date() + repairWait
	while connection == nil, Date() < deadline {
		Thread.sleep(forTimeInterval: 0.2)
		(connection, failure) = try connect()
	}
}
guard let connection else {
	// A missing socket means no host has served it; a refused one, a host that stopped serving.
	if failure == ENOENT { refuse("HOST_NOT_RUNNING", "No host is serving \(socketPath).") }
	refuse("HOST_NOT_SERVING", "The host at \(socketPath) refused the connection (\(String(cString: strerror(failure)))).")
}

do {
	var request: [(String, JSON)] = [("id", 1), ("tool", JSON(tool)), ("arguments", toolArguments)]
	if verbose { request.append(("verbose", true)) }
	try connection.send(.object(request))
	while true {
		let frame = try connection.receive()
		guard frame["id"]?.int == 1 else { continue }
		if let result = frame["result"] { finish(.object([("result", result)]), status: 0) }
		refuse("DESKTOP_ERROR", frame["error"]?.string ?? "The host replied without a result.")
	}
} catch {
	// The request may have reached the host, so this isn't a refusal: the caller reports it as an error.
	refuse("DESKTOP_ERROR", "The connection to the host failed: \(error).")
}
