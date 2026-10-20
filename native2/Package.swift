// swift-tools-version: 6.2

import PackageDescription

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
	],
	targets: [
		.target(name: "DesktopProtocol"),
		.target(name: "DesktopCore", dependencies: ["DesktopProtocol"]),
		.target(name: "DesktopMac", dependencies: ["DesktopProtocol"], linkerSettings: [.linkedLibrary("bsm")]),
		.target(name: "DesktopHost", dependencies: ["DesktopProtocol", "DesktopCore", "DesktopMac"]),
		.executableTarget(name: "desktop-tools-host", dependencies: ["DesktopHost"]),
		.target(name: "DesktopTools", dependencies: ["DesktopProtocol", "DesktopCore", "DesktopMac", "DesktopHost"]),
		.executableTarget(name: "desktop-tools-mcp", dependencies: ["DesktopProtocol"]),
		.executableTarget(name: "desktop-tools-client", dependencies: ["DesktopProtocol"]),
		.testTarget(name: "CoreTests", dependencies: ["DesktopCore", "DesktopProtocol"]),
		.testTarget(name: "RuntimeTests", dependencies: ["DesktopTools", "DesktopHost", "DesktopMac", "DesktopProtocol"]),
	],
	swiftLanguageModes: [.v6]
)
