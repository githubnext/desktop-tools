import Foundation
import Testing
@testable import Tachikoma

struct TachikomaConfigGuidanceSnapshotTests {
    @Test
    func `init guidance matches snapshot`() throws {
        let rendered = TKConfigMessages.initGuidance
            .map { $0.replacingOccurrences(of: "{path}", with: "/tmp/config.json") }
            .joined(separator: "\n")

        let snapshot = try String(contentsOfFile: "Tests/TachikomaTests/CLITests/__snapshots__/config_init.txt")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(rendered.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot)
    }
}
