// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "DesktopTools",
	platforms: [.macOS(.v15)],
	products: [
		.library(name: "DesktopTools", type: .dynamic, targets: ["DesktopTools"]),
		.executable(name: "desktop-tools-client", targets: ["DesktopToolsClient"]),
	],
	dependencies: [
		.package(url: "https://github.com/openclaw/Peekaboo.git", exact: "4.8.0"),
	],
	targets: [
		.target(
			name: "DesktopToolsIdentity",
			path: "sources/identity",
			linkerSettings: [.linkedFramework("Security")]
		),
		.target(
			name: "DesktopTools",
			dependencies: [
				"DesktopToolsIdentity",
				.product(name: "PeekabooBridge", package: "Peekaboo"),
				.product(name: "PeekabooAutomationKit", package: "Peekaboo"),
			],
			path: "sources/runtime"
		),
		.executableTarget(
			name: "DesktopToolsClient",
			dependencies: [
				"DesktopToolsIdentity",
				.product(name: "PeekabooBridge", package: "Peekaboo"),
				.product(name: "PeekabooAutomationKit", package: "Peekaboo"),
				.product(name: "PeekabooFoundation", package: "Peekaboo"),
			],
			path: "sources/client"
		),
	],
	swiftLanguageModes: [.v6]
)
