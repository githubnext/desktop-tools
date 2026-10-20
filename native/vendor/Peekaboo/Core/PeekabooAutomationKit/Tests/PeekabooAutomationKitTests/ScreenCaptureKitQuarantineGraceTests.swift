import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ScreenCaptureKitQuarantineGraceTests {
    @Test
    func `a late completion inside the grace period admits the waiting call`() async throws {
        let coordinator = ScreenCaptureKitOperationCoordinator(lockFilePath: nil, quarantineGraceSeconds: 5)
        let release = try await self.quarantine(coordinator)

        let waitingCall = Task { @MainActor in
            try await coordinator.run(seconds: 0.5, operationName: "waiting capture") { 2 }
        }
        try await Task.sleep(for: .milliseconds(100))
        await release.open()

        #expect(try await waitingCall.value == 2)
        #expect(!coordinator.isQuarantined)
    }

    @Test
    func `an expired grace period refuses with a temporary retry message`() async throws {
        let coordinator = ScreenCaptureKitOperationCoordinator(lockFilePath: nil, quarantineGraceSeconds: 0.1)
        let release = try await self.quarantine(coordinator)
        defer { Task { await release.open() } }

        var admitted = false
        let start = ContinuousClock.now
        do {
            _ = try await coordinator.run(seconds: 0.5, operationName: "refused capture") {
                admitted = true
                return 2
            }
            Issue.record("A quarantined capture gate admitted another operation")
        } catch let error as PeekabooError {
            #expect(error.userMessage.contains("an earlier blocked capture call"))
            #expect(error.userMessage.contains("temporary"))
            #expect(error.userMessage.contains("retry"))
        }
        #expect(!admitted)
        #expect(start.duration(to: .now) >= .milliseconds(100))
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test
    func `the quarantine refusal blames another capture`() {
        let error = ScreenCaptureKitOperationCoordinator.quarantineError(abandonedOperation: "fixture")
        #expect(error.userMessage.contains("another capture on this Mac"))
    }

    /// Times out one blocked call so the coordinator stays quarantined until the returned latch opens.
    private func quarantine(_ coordinator: ScreenCaptureKitOperationCoordinator) async throws -> AsyncTestLatch {
        let started = AsyncTestLatch()
        let release = AsyncTestLatch()
        let blocked = Task { @MainActor in
            try await coordinator.run(seconds: 0.05, operationName: "blocked capture") {
                await started.open()
                await release.wait()
                return 1
            }
        }
        await started.wait()
        _ = await blocked.result
        for _ in 0..<100 where !coordinator.isQuarantined {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.isQuarantined)
        return release
    }
}
