import AppKit
import DesktopAppLink
import DesktopProtocol
import Foundation

// The signed client embedders run, since the host serves only its own app's client:
//
//   desktop-tools-client <socket> <tool> [--verbose]   one tool call, with its arguments as a JSON object on stdin
//   desktop-tools-client <socket> --serve              many calls over one connection, as createDesktop makes with wire 2
//   desktop-tools-client [<socket>] status | repair   what native/'s client prints for the same commands
//
// One call prints one JSON line: {"result": <MCP tool result>}, or {"error": {"code", "message"}} and exits 1 when
// nothing ran. --serve reads one request per line, {"id", "tool", "arguments"?, "verbose"?} or {"cancel": id}, and
// writes one line per reply tagged with its id, {"id", "result"} or {"id", "error": {"code", "message"}}; when it can't
// connect it prints the same untagged error as one call, and nothing ran. DESKTOP_TOOLS_AGENT in its environment names
// the agent in the host's window outline, as native/'s client does.

func finish(_ value: JSON, status: Int32) -> Never {
	FileHandle.standardOutput.write(Data((value.text + "\n").utf8))
	exit(status)
}

func refuse(_ code: String, _ message: String) -> Never {
	finish(.object([("error", .object([("code", JSON(code)), ("message", JSON(message))]))]), status: 1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
var positional = arguments.filter { !$0.hasPrefix("--") }

// Status and repair default to the socket beside the link the app keeps in its state folder, and print what native/'s
// client prints: {"success": true, "data": <report>}, or {"success": false, "error": {"code", "message"}}.
if positional.count == 1, positional[0] == "status" || positional[0] == "repair" {
	let link = CommandLine.arguments[0]
	if link.contains("/") {
		positional.insert(((link as NSString).deletingLastPathComponent as NSString)
			.appendingPathComponent("desktop.sock"), at: 0)
	}
}
if positional.count == 2, positional[1] == "status" || positional[1] == "repair" {
	let report = positional[1] == "status" ? HostRepair.status(positional[0]) : HostRepair.repair(positional[0])
	let failed = positional[1] == "repair" && report.reach != .serving
	let output = failed
		? try! JSONEncoder().encode(HostFailure(error: .init(code: report.failure.code,
			message: "\(report.failure.code): \(report.failure.message)")))
		: try! JSONEncoder().encode(HostSuccess(data: report))
	FileHandle.standardOutput.write(output + Data([10]))
	exit(failed ? 1 : 0)
}
// A Node MCP server or createDesktop from before 0.17.0 runs this client as native/'s, `<socket> <op> [args…]`, and
// reads {"success", "error"}. Answer it in that shape, so the agent sees how to update instead of an unsupported reply.
if positional.count >= 2, !positional[1].hasPrefix("desktop_") {
	let app = HostApp.containing()
	let server = app.map { $0.url.appendingPathComponent("Contents/MacOS/desktop-tools-mcp").path } ?? "the app's desktop-tools-mcp"
	// The old server adds the code before the message and a period after it.
	let message = "\(app?.name ?? "The desktop host app") runs a newer host than this MCP server or embedder speaks, "
		+ "so nothing ran. Ask the user to set up the MCP server as \(server), or to update a pinned npx setup to v0.17.0 or later"
	let failure = try! JSONEncoder().encode(HostFailure(error: .init(code: "CLIENT_OUTDATED", message: message)))
	FileHandle.standardOutput.write(failure + Data([10]))
	exit(1)
}
let serving = arguments.contains("--serve")
guard positional.count == (serving ? 1 : 2) else {
	refuse("USAGE", "Usage: desktop-tools-client <socket> <tool> [--verbose], with the tool's arguments as JSON on stdin, "
		+ "desktop-tools-client <socket> --serve, or desktop-tools-client [<socket>] status | repair.")
}
let socketPath = positional[0]

/// Connects and exchanges hellos; nil with the connect errno when no host accepted.
func connect() throws -> (Connection?, Int32) {
	let connection: Connection
	do { connection = try Connection.connect(to: socketPath) } catch let WireError.system("connect", code) {
		return (nil, code)
	}
	// No call is sent before the hellos, so a host that drops the connection here ran nothing. A signed host drops a
	// client that isn't signed as its own app's.
	let hello: JSON
	do {
		try connection.send(.object([("hello", JSON(wireVersion))]))
		hello = try connection.receive()
	} catch {
		refuse("HOST_NOT_SERVING", "The host at \(socketPath) closed the connection before serving it (\(error)). A signed host serves only the client bundled with its app.")
	}
	guard hello["hello"]?.int == wireVersion else {
		refuse("DESKTOP_ERROR", "The host at \(socketPath) speaks another wire version.")
	}
	return (connection, 0)
}

let host = HostApp.containing()
var (connection, failure) = try connect()
if connection == nil, let host {
	host.open()
	let deadline = Date() + repairWait
	while connection == nil, Date() < deadline {
		Thread.sleep(forTimeInterval: 0.2)
		(connection, failure) = try connect()
	}
}
guard let connection else {
	if host != nil {
		var report = HostReport(socket: socketPath, host: host)
		report.opened = true
		refuse(report.failure.code, report.failure.message)
	}
	// Run outside an app: a missing socket means no host has served it; a refused one, a host that stopped serving.
	if failure == ENOENT { refuse("HOST_NOT_RUNNING", "No host is serving \(socketPath).") }
	refuse("HOST_NOT_SERVING", "The host at \(socketPath) refused the connection (\(String(cString: strerror(failure)))).")
}

if serving { serve(connection) }
let tool = positional[1]
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
