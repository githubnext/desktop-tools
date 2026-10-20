import DesktopCore
import DesktopProtocol
import Foundation
import Testing

/// The compact shape must match src/compact.ts byte for byte, so these run Node's on the same recorded results.
@Suite struct Compact {
	static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized

	static func node(_ fixture: URL, allWindows: Bool) throws -> String {
		let script = """
		import { readFileSync } from "node:fs";
		import { compactResult } from "\(repository.appendingPathComponent("dist/compact.js").path)";
		process.stdout.write(compactResult(readFileSync(process.argv[1], "utf8"), { allWindows: \(allWindows) }));
		"""
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["node", "--input-type=module", "-e", script, fixture.path]
		let pipe = Pipe()
		process.standardOutput = pipe
		try process.run()
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return String(decoding: data, as: UTF8.self)
	}

	@Test(arguments: ["inspect-textedit", "windows-textedit"], [false, true])
	func matchesNode(_ name: String, allWindows: Bool) throws {
		let fixture = Self.repository.appendingPathComponent("test/fixtures/compact/\(name).json")
		let text = try String(contentsOf: fixture, encoding: .utf8)
		#expect(compactResult(text, allWindows: allWindows) == (try Self.node(fixture, allWindows: allWindows)))
	}

	@Test func leavesPlainTextAlone() {
		#expect(compactResult("Choose all true or false.") == "Choose all true or false.")
	}
}
