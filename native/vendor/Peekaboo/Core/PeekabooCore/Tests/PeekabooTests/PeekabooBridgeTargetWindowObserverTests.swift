import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@MainActor
struct PeekabooBridgeTargetWindowObserverTests {
    @Test
    func `exact window observations and snapshot mutations report their window`() async throws {
        let snapshotID = SnapshotReference.generate().rawValue
        let snapshots = try await InMemorySnapshotManager.containing(ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: WindowContext(
                    applicationName: "Fixture",
                    applicationProcessId: 321,
                    applicationProcessStartIdentity: 654,
                    windowID: 77))))
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: snapshots),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let reports = TargetWindowReports()
        server.targetWindowObserver = { reports.append($0) }
        let peer = PeekabooBridgePeer(
            processIdentifier: 99,
            userIdentifier: getuid(),
            bundleIdentifier: "dev.example.client",
            teamIdentifier: "TEAMID")

        await server.reportTargetWindow(Self.plan(.desktopObservation(.init(target: .pid(123, window: .id(45))))), peer: peer)
        await server.reportTargetWindow(Self.plan(.beginSnapshotMutation(.init(snapshotId: snapshotID))), peer: peer)

        #expect(reports.values == [
            .init(clientProcessIdentifier: 99, processIdentifier: 123, windowID: 45),
            .init(clientProcessIdentifier: 99, processIdentifier: 321, windowID: 77),
        ])
    }

    @Test
    func `requests without one exact window report nothing`() async {
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager()),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let reports = TargetWindowReports()
        server.targetWindowObserver = { reports.append($0) }
        let peer = PeekabooBridgePeer(
            processIdentifier: 99,
            userIdentifier: getuid(),
            bundleIdentifier: "dev.example.client",
            teamIdentifier: "TEAMID")

        await server.reportTargetWindow(Self.plan(.desktopObservation(.init(target: .screen(index: nil)))), peer: peer)
        await server.reportTargetWindow(Self.plan(.desktopObservation(.init(target: .pid(123, window: nil)))), peer: peer)
        await server.reportTargetWindow(Self.plan(.beginSnapshotMutation(.init(snapshotId: "missing"))), peer: peer)
        await server.reportTargetWindow(Self.plan(.listApplications), peer: peer)
        await server.reportTargetWindow(Self.plan(.desktopObservation(.init(target: .pid(123, window: .id(45))))), peer: nil)

        #expect(reports.values.isEmpty)
    }

    private static func plan(
        _ request: PeekabooBridgeRequest) -> PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan
    {
        PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
    }
}

private final class TargetWindowReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [PeekabooBridgeTargetWindow] = []

    var values: [PeekabooBridgeTargetWindow] {
        self.lock.withLock { self.reports }
    }

    func append(_ report: PeekabooBridgeTargetWindow) {
        self.lock.withLock { self.reports.append(report) }
    }
}
