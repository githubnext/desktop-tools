import DesktopCore
import DesktopProtocol
import Foundation
import Testing

/// The compact shape is what Node's src/compact.ts produced byte for byte; these are its outputs for the recorded results,
/// written before Node's copy was removed: <name>.compact.json without allWindows, <name>.all.json with it.
@Suite struct Compact {
	static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../fixtures/compact").standardized

	@Test(arguments: ["inspect-textedit", "windows-textedit"], [false, true])
	func matchesRecorded(_ name: String, allWindows: Bool) throws {
		let text = try String(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"), encoding: .utf8)
		let expected = try String(contentsOf: Self.fixtures.appendingPathComponent("\(name).\(allWindows ? "all" : "compact").json"), encoding: .utf8)
		#expect(compactResult(text, allWindows: allWindows) == expected)
	}

	@Test func leavesPlainTextAlone() {
		#expect(compactResult("Choose all true or false.") == "Choose all true or false.")
	}
}
