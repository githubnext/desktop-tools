import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite("Exact file-dialog path")
struct DialogFileDialogPathTests {
    @Test
    func `an existing folder is chosen as the panel's folder`() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let choice = try FileDialogPathChoice(folder + "/")
        #expect(choice.directory == folder)
        #expect(choice.path == folder)
        #expect(choice.fileName == nil)
    }

    @Test
    func `any other path names a file in its resolved folder`() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let link = folder + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder)
        defer { try? FileManager.default.removeItem(atPath: link) }

        let choice = try FileDialogPathChoice(link + "/./Report.txt")
        #expect(choice.directory == folder)
        #expect(choice.fileName == "Report.txt")
        #expect(choice.path == folder + "/Report.txt")
    }

    @Test
    func `a path in a missing folder is refused before input`() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }

        #expect(throws: DesktopActionFailure.self) {
            try FileDialogPathChoice(folder + "/missing/Report.txt")
        }
    }

    @Test
    func `requests need an exact owner and one absolute path`() throws {
        let target = try DialogTargetSelector(processIdentifier: 42, windowID: 7)
        #expect(throws: DesktopActionFailure.self) {
            try FileDialogPathRequest(target: target, path: "relative/path")
        }
        #expect(throws: DesktopActionFailure.self) {
            try FileDialogPathRequest(target: target, path: "/tmp/a\0b")
        }
        #expect(throws: DesktopActionFailure.self) {
            try FileDialogPathRequest(target: target, path: "/" + String(repeating: "a", count: 4096))
        }

        let request = try FileDialogPathRequest(target: target, path: "/tmp/Report.txt")
        let decoded = try JSONDecoder().decode(FileDialogPathRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)

        let invalid = try JSONEncoder().encode(request)
        let json = try #require(String(data: invalid, encoding: .utf8))
            .replacingOccurrences(of: "\\/tmp\\/Report.txt", with: "Report.txt")
            .replacingOccurrences(of: "/tmp/Report.txt", with: "Report.txt")
        #expect(throws: DesktopActionFailure.self) {
            try JSONDecoder().decode(FileDialogPathRequest.self, from: Data(json.utf8))
        }
    }

    private static func temporaryFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("file-dialog-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return FileDialogPathChoice.canonical(url.path)
    }
}
