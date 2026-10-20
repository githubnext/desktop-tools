import AppKit
import Foundation
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ClipboardAttachmentWriteTests: XCTestCase {
    private let urls = ["file:///tmp/first.png", "file:///tmp/second%20report.pdf"]

    func testReplacingWriteNeverReadsThePriorClipboardAndHasNothingToRestore() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("synthetic prior", forType: .string))
        var policyReads = 0
        let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in
            policyReads += 1
            return .init(policy: .alwaysDeny)
        })

        let transaction = service.prepareReplacingWrite()
        _ = try transaction.write(ClipboardWriteRequest(fileURLs: self.urls))

        XCTAssertEqual(policyReads, 0)
        XCTAssertFalse(transaction.priorClipboardPresent)
        XCTAssertTrue(transaction.didMutate)
        XCTAssertEqual(pasteboard.pasteboardItems?.map { $0.data(forType: .fileURL) }, self.urls.map { Data($0.utf8) })
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertThrowsError(try transaction.cleanup())
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
    }

    func testTemporaryFilesWriteRestoresThePriorClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("synthetic prior", forType: .string))
        let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in .init(policy: .alwaysAllow) })

        let transaction = try service.prepareTemporaryWrite()
        _ = try transaction.write(ClipboardWriteRequest(fileURLs: self.urls))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)

        XCTAssertEqual(try transaction.cleanup().status, .restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic prior")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testTemporaryFilesWriteKeepsNewerContents() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("synthetic prior", forType: .string))
        let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in .init(policy: .alwaysAllow) })

        let transaction = try service.prepareTemporaryWrite()
        _ = try transaction.write(ClipboardWriteRequest(fileURLs: self.urls))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("synthetic newer", forType: .string))

        XCTAssertEqual(try transaction.cleanup().status, .preservedNewerContents)
        XCTAssertEqual(pasteboard.string(forType: .string), "synthetic newer")
    }
}
