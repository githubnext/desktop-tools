import Foundation
import XCTest
@testable import PeekabooAutomationKit

final class FinderFolderPasteTests: XCTestCase {
    func testFilesArePresentOnlyOnceEveryNameExistsInTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let expectation = FolderPasteExpectation(folder: folder, names: ["first.txt", "second folder"])
        XCTAssertNil(expectation.existing())
        XCTAssertFalse(expectation.present())

        try Data("one".utf8).write(to: folder.appendingPathComponent("first.txt"))
        XCTAssertEqual(expectation.existing(), "first.txt")
        XCTAssertFalse(expectation.present())

        // A dangling symbolic link still holds the name, as Finder sees it.
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("second folder"), withDestinationURL: folder.appendingPathComponent("missing"))
        XCTAssertTrue(expectation.present())
    }

    func testTheNameRefusalEndsWithTheSharedSuffix() {
        let message = FinderPasteRefusal.message(name: "report.pdf", folder: "/tmp/destination")
        XCTAssertTrue(message.hasPrefix("report.pdf already exists in /tmp/destination."))
        XCTAssertTrue(message.hasSuffix(FinderPasteRefusal.suffix))
    }
}
