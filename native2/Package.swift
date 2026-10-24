// swift-tools-version: 6.2

import Foundation
import PackageDescription

// The npm package ships Sources without Tests, and SwiftPM refuses a test target whose folder is missing.
let tests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests")

// The single-codebase spike from #143: no Peekaboo and no Node. Only DesktopMac touches macOS.
let package = Package(
	name: "DesktopTools2",
	platforms: [.macOS(.v15)],
	products: [
		.executable(name: "desktop-tools-host", targets: ["desktop-tools-host"]),
		.executable(name: "desktop-tools-mcp", targets: ["desktop-tools-mcp"]),
		// One call per run, for createDesktop's wire 2 and embedders that spawn a client per request.
		.executable(name: "desktop-tools-client", targets: ["desktop-tools-client"]),
		// The embedding runtime the menu bar app loads, with native/'s C ABI (docs/embed.md).
		.library(name: "DesktopTools", type: .dynamic, targets: ["DesktopTools"]),
		// The menu bar app that loads it, a copy of native/'s with the same callers module.
		.executable(name: "desktop-tools-app", targets: ["desktop-tools-app"]),
	],
	targets: [
		.target(name: "DesktopProtocol"),
		.target(name: "DesktopCore", dependencies: ["DesktopProtocol"]),
		.target(name: "DesktopMac", dependencies: ["DesktopProtocol"]),
		// Who is at the other end of the socket, by signature: the host checks its client, and the client its host.
		.target(name: "DesktopPeer", linkerSettings: [.linkedLibrary("bsm")]),
		.target(name: "DesktopHost", dependencies: ["DesktopProtocol", "DesktopCore", "DesktopMac", "DesktopPeer"]),
		.executableTarget(name: "desktop-tools-host", dependencies: ["DesktopHost"]),
		.target(name: "DesktopTools", dependencies: ["DesktopProtocol", "DesktopCore", "DesktopMac", "DesktopHost", "DesktopPeer"]),
		// How the client and MCP server bundled in the app find its socket, and open the app when nothing serves it.
		.target(name: "DesktopAppLink", dependencies: ["DesktopPeer"]),
		.executableTarget(name: "desktop-tools-mcp", dependencies: ["DesktopProtocol", "DesktopAppLink"]),
		.executableTarget(name: "desktop-tools-client", dependencies: ["DesktopProtocol", "DesktopAppLink"]),
		.executableTarget(name: "desktop-tools-app", dependencies: ["DesktopCore"]),
	] + (tests ? [
		.testTarget(name: "CoreTests", dependencies: ["DesktopCore", "DesktopProtocol"]),
		.testTarget(name: "RuntimeTests", dependencies: ["DesktopTools", "DesktopHost", "DesktopMac", "DesktopProtocol", "DesktopPeer", "DesktopAppLink"]),
	] : []),
	swiftLanguageModes: [.v6]
)
