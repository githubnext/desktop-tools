import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

extension DesktopOperationLaneCoordinatorTests {
    @Test
    func `A lock timeout names the processes that have the lock open`() async throws {
        let root = Self.temporaryDirectory(named: "lock-holders")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("global.lock").path
        let holder = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        try #require(holder >= 0)
        defer { close(holder) }
        try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(holder, LOCK_UN) }
        let instant = ContinuousClock.now
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root, lockWait: .zero, now: { instant })

        do {
            try await coordinator.run(scope: .global, access: .write) {}
            Issue.record("Expected an admission timeout")
        } catch let failure as DesktopActionFailure {
            Self.expectAdmissionTimeout(failure, path: path)
            #expect(failure.message.contains("one of which holds it"))
            #expect(failure.message.contains("pid \(getpid()), this process"))
            #expect(failure.hint?.contains("holds the desktop lock") == true)
        }
    }

    @Test
    func `A lock file nobody has open has no listed holders`() throws {
        let root = Self.temporaryDirectory(named: "lock-holders-none")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("global.lock").path
        #expect(FileManager.default.createFile(atPath: path, contents: nil))

        #expect(LockFileHolders.describe(path: path).isEmpty)
        #expect(LockFileHolders.describe(path: root.appendingPathComponent("missing.lock").path).isEmpty)
    }
}
