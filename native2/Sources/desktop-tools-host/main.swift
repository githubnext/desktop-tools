import AppKit
import DesktopHost
import DesktopPeer
import DesktopProtocol
import DesktopTools

// The spike's host, run from a terminal until it moves into the menu bar app. It serves its own socket,
// so it runs beside the installed Desktop Tools.
//
// An app that runs it as its own helper, as AIDE does, passes:
//   --client <team>:<identifier>  serve only that signed client, by the peer's audit token
//   --protect <pid>               refuse agent input to that process's windows and menus (SELF_TARGET_REFUSED)
//   --parent <pid>                exit when that process does
//   --overlays                    draw the agent cursor and the outline on the window being used, as the app does
//   --confirm-stdio               ask that app to confirm agent-supplied passwords over this process's stdout and
//                                 stdin, one JSON object a line: out {"confirm": id, "request": {...}} and
//                                 {"withdraw": id}; in {"answer": id, "allowed": bool}
// With --overlays or --confirm-stdio it serves through the embedding runtime (DesktopTools), so the client must be
// signed by this host's own team, as the app's is.
// and `--tools` prints the tool list and server instructions as JSON, then exits.
var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ flag: String) -> String? {
	guard let index = arguments.firstIndex(of: flag) else { return nil }
	guard index + 1 < arguments.count else {
		FileHandle.standardError.write(Data("desktop-tools-host: \(flag) needs a value\n".utf8))
		exit(2)
	}
	defer { arguments.removeSubrange(index...index + 1) }
	return arguments[index + 1]
}
if arguments.contains("--tools") {
	print(JSON.object([("tools", Contract.tools), ("instructions", JSON(Contract.instructions))]).text)
	exit(0)
}
let client = option("--client").map { spec -> ClientRequirement in
	guard let colon = spec.firstIndex(of: ":") else {
		FileHandle.standardError.write(Data("desktop-tools-host: --client takes <team>:<identifier>\n".utf8))
		exit(2)
	}
	return ClientRequirement(team: String(spec[..<colon]), identifier: String(spec[spec.index(after: colon)...]))
}
if let pid = option("--protect").flatMap({ pid_t($0) }) { Protected.shared.set([pid]) }
var parentWatch: DispatchSourceProcess?
if let parent = option("--parent").flatMap({ pid_t($0) }) {
	// Watch first, then check, so an exit between the two still ends this host.
	let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
	watch.setEventHandler { exit(0) }
	watch.resume()
	parentWatch = watch
	if getppid() != parent { exit(0) }
}
@MainActor func flag(_ name: String) -> Bool {
	guard let index = arguments.firstIndex(of: name) else { return false }
	arguments.remove(at: index)
	return true
}
let overlays = flag("--overlays")
let confirmStdio = flag("--confirm-stdio")
let path = arguments.first ?? (defaultStateFolder() as NSString).appendingPathComponent("desktop.sock")
var server: Server?
if overlays || confirmStdio {
	guard let client else {
		FileHandle.standardError.write(Data("desktop-tools-host: --overlays and --confirm-stdio need --client\n".utf8))
		exit(2)
	}
	guard let own = ownSigning(), own.team == client.team else {
		FileHandle.standardError.write(Data("desktop-tools-host: --client's team must be this host's own signing team\n".utf8))
		exit(2)
	}
	if overlays {
		DesktopTools.setCursor(true)
		DesktopTools.setHighlight(true)
	}
	if confirmStdio { Confirmations.serve() }
	path.withCString { socket in client.identifier.withCString { DesktopTools.start(socket, $0) } }
} else {
	let plain = Server(path: path, client: client)
	do {
		try plain.start()
	} catch {
		let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
		FileHandle.standardError.write(Data("desktop-tools-host: \(message)\n".utf8))
		exit(1)
	}
	server = plain
}
FileHandle.standardError.write(Data("desktop-tools-host: serving \(path)\n".utf8))
// AppKit state such as NSWorkspace's running applications updates only while the main run loop turns. The overlays
// are windows, which a prohibited app can't show; an accessory app has no Dock icon or menu bar and never activates
// unless asked.
NSApplication.shared.setActivationPolicy(overlays ? .accessory : .prohibited)
NSApplication.shared.run()

/// Password confirmations, asked of the app that runs this host over stdout and answered on stdin.
enum Confirmations {
	static func serve() {
		DesktopTools.setConfirmationHandlers({ id, request in
			let json = (try? JSON(parsing: String(cString: request))) ?? .object([])
			Confirmations.write(.object([("confirm", JSON(Int(id))), ("request", json)]))
		}, { id in
			Confirmations.write(.object([("withdraw", JSON(Int(id)))]))
		})
		Thread.detachNewThread {
			// Answers until the app closes stdin; a line that isn't an answer is ignored.
			while let line = readLine(strippingNewline: true) {
				guard let value = try? JSON(parsing: line), let id = value["answer"]?.int, id > 0,
				      let allowed = value["allowed"]?.bool else { continue }
				DesktopTools.answerConfirmation(UInt64(id), allowed)
			}
		}
	}

	static func write(_ value: JSON) {
		FileHandle.standardOutput.write(Data((value.text + "\n").utf8))
	}
}
