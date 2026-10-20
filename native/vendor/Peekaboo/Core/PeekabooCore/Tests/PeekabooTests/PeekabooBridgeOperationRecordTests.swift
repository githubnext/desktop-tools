import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@MainActor
struct PeekabooBridgeOperationRecordTests {
    @Test
    func `finished requests report their operation, window and outcome`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager()),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let records = OperationRecords()
        server.operationObserver = { records.append($0) }
        let observe = Self.plan(.desktopObservation(.init(target: .pid(123, window: .id(45)))))

        _ = try await server.recordingOperation(observe, peer: Self.peer) {
            PeekabooBridgeHandledResponse(response: .ok)
        }
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await server.recordingOperation(observe, peer: Self.peer) {
                throw PeekabooBridgeErrorEnvelope(code: .permissionDenied, message: "refused")
            }
        }
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await server.recordingOperation(Self.plan(.listApplications), peer: Self.peer) {
                throw PeekabooBridgeErrorEnvelope(code: .timeout, message: "late", operationMayHaveCompleted: true)
            }
        }

        #expect(records.values.map(\.outcome) == [.completed, .refused, .unknown])
        #expect(records.values.allSatisfy { $0.clientProcessIdentifier == 99 })
        #expect(records.values[0].operation == .desktopObservation)
        #expect(records.values[0].targetProcessIdentifier == 123)
        #expect(records.values[0].targetWindowID == 45)
        #expect(records.values[0].mutatesDesktop == false)
        #expect(records.values[2].targetProcessIdentifier == nil)
        #expect(records.values[2].targetWindowID == nil)
    }

    @Test
    func `requests without an authorized peer report nothing`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager()),
            hostKind: .gui,
            allowlistedTeams: ["OTHERTEAM"],
            allowlistedBundles: [])
        let records = OperationRecords()
        server.operationObserver = { records.append($0) }

        _ = try await server.recordingOperation(Self.plan(.listApplications), peer: nil) {
            PeekabooBridgeHandledResponse(response: .ok)
        }
        _ = try await server.recordingOperation(Self.plan(.listApplications), peer: Self.peer) {
            PeekabooBridgeHandledResponse(response: .ok)
        }

        #expect(records.values.isEmpty)
    }

    @Test
    func `an admission refusal stops the request before dispatch and is recorded as refused`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager()),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let records = OperationRecords()
        server.operationObserver = { records.append($0) }
        let asked = AdmissionQuestions()
        server.operationAdmission = { admission in
            asked.append(admission)
            return admission.operation == .listApplications ? "Input is paused." : nil
        }

        do {
            _ = try await server.route(Self.plan(.listApplications), peer: Self.peer)
            Issue.record("The paused request was dispatched.")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.message == "Input is paused.")
            #expect(envelope.operationMayHaveCompleted == false)
        }

        #expect(asked.values == [.init(
            operation: .listApplications, mutatesDesktop: false, clientProcessIdentifier: 99,
            targetProcessIdentifier: nil)])
        #expect(records.values.map(\.outcome) == [.refused])
    }

    @Test
    func `admission learns the process a request targets`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager()),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let asked = AdmissionQuestions()
        server.operationAdmission = { admission in
            asked.append(admission)
            return "Refused."
        }

        _ = try? await server.route(
            Self.plan(.desktopObservation(.init(target: .pid(123, window: .id(45))))), peer: Self.peer)

        _ = try? await server.route(
            Self.plan(.activateApplication(.init(
                identifier: "Desktop Tools",
                expectedIdentity: ApplicationProcessIdentity(processIdentifier: 456, processStartIdentity: 7)))),
            peer: Self.peer)

        #expect(asked.values.map(\.targetProcessIdentifier) == [123, 456])
        #expect(asked.values.map(\.clientProcessIdentifier) == [99, 99])
    }

    @Test
    func `an admission refusal at the handshake leaves the client no operations`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(snapshots: InMemorySnapshotManager()),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let asked = AdmissionQuestions()
        server.operationAdmission = { admission in
            asked.append(admission)
            return "Not approved."
        }

        do {
            _ = try await server.handleHandshake(
                .init(
                    protocolVersion: PeekabooBridgeConstants.protocolVersion,
                    client: .init(bundleIdentifier: nil, teamIdentifier: nil, processIdentifier: 99)),
                peer: Self.peer,
                permissions: PermissionsStatus(
                    screenRecording: true, accessibility: true, appleScript: false, postEvent: false))
            Issue.record("The refused client completed its handshake.")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.message == "Not approved.")
        }

        #expect(asked.values == [.init(
            operation: .permissionsStatus, mutatesDesktop: false, clientProcessIdentifier: 99,
            targetProcessIdentifier: nil)])
    }

    @Test
    func `mutation states map to completed, unknown or refused`() {
        #expect(PeekabooBridgeServer.recordedOutcome(nil) == .completed)
        #expect(PeekabooBridgeServer.recordedOutcome(.confirmedChange) == .completed)
        #expect(PeekabooBridgeServer.recordedOutcome(.confirmedNoChange) == .completed)
        #expect(PeekabooBridgeServer.recordedOutcome(.dispatchedUnverified) == .unknown)
        #expect(PeekabooBridgeServer.recordedOutcome(.partial) == .unknown)
        #expect(PeekabooBridgeServer.recordedOutcome(.suspectedNoop) == .unknown)
        #expect(PeekabooBridgeServer.recordedOutcome(.indeterminate) == .unknown)
        #expect(PeekabooBridgeServer.recordedOutcome(.refused) == .refused)
    }

    private static let peer = PeekabooBridgePeer(
        processIdentifier: 99,
        userIdentifier: getuid(),
        bundleIdentifier: "dev.example.client",
        teamIdentifier: "TEAMID")

    private static func plan(
        _ request: PeekabooBridgeRequest) -> PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan
    {
        PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
    }
}

private final class AdmissionQuestions: @unchecked Sendable {
    private let lock = NSLock()
    private var questions: [PeekabooBridgeOperationAdmission] = []

    var values: [PeekabooBridgeOperationAdmission] {
        self.lock.withLock { self.questions }
    }

    func append(_ admission: PeekabooBridgeOperationAdmission) {
        self.lock.withLock { self.questions.append(admission) }
    }
}

private final class OperationRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PeekabooBridgeOperationRecord] = []

    var values: [PeekabooBridgeOperationRecord] {
        self.lock.withLock { self.records }
    }

    func append(_ record: PeekabooBridgeOperationRecord) {
        self.lock.withLock { self.records.append(record) }
    }
}
