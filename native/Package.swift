// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "DesktopTools",
	platforms: [.macOS(.v15)],
	products: [
		.library(name: "DesktopTools", type: .dynamic, targets: ["DesktopTools"]),
		.executable(name: "desktop-tools-client", targets: ["DesktopToolsClient"]),
		.executable(name: "desktop-tools-app", targets: ["DesktopToolsApp"]),
	],
	dependencies: [
		.package(path: "vendor/Peekaboo"),
	],
	targets: [
		.target(
			name: "DesktopToolsIdentity",
			path: "sources/identity",
			linkerSettings: [.linkedFramework("Security")]
		),
		.target(name: "DesktopToolsCallers", path: "sources/callers"),
		.target(
			name: "DesktopTools",
			dependencies: [
				"DesktopToolsIdentity",
				"DesktopToolsCallers",
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
		.executableTarget(name: "DesktopToolsApp", dependencies: ["DesktopToolsCallers"], path: "sources/app"),
		.testTarget(name: "DesktopToolsCallersTests", dependencies: ["DesktopToolsCallers"], path: "tests/callers"),
	],
	swiftLanguageModes: [.v6]
)
