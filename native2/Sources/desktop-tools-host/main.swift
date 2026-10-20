import AppKit
import DesktopHost
import DesktopProtocol

// The spike's host, run from a terminal until it moves into the menu bar app. It serves its own socket,
// so it runs beside the installed Desktop Tools.
let path = CommandLine.arguments.dropFirst().first
	?? (defaultStateFolder() as NSString).appendingPathComponent("desktop.sock")
let server = Server(path: path)
do {
	try server.start()
} catch {
	FileHandle.standardError.write(Data("desktop-tools-host: \(error)\n".utf8))
	exit(1)
}
FileHandle.standardError.write(Data("desktop-tools-host: serving \(path)\n".utf8))
// AppKit state such as NSWorkspace's running applications updates only while the main run loop turns.
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
