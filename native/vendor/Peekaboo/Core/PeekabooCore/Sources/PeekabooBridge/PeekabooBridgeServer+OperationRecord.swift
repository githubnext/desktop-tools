import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// One request an embedder may refuse before dispatch: the operation, its client and the process it targets.
public struct PeekabooBridgeOperationAdmission: Sendable, Equatable {
    public let operation: PeekabooBridgeOperation
    /// Whether the operation can change the desktop, as its result contract says.
    public let mutatesDesktop: Bool
    /// The socket peer that sent the request, from its audit token, when the transport has one.
    public let clientProcessIdentifier: pid_t?
    /// The process the request targets, when it names one or its snapshot, window or status item does.
    public let targetProcessIdentifier: pid_t?

    public init(
        operation: PeekabooBridgeOperation,
        mutatesDesktop: Bool,
        clientProcessIdentifier: pid_t?,
        targetProcessIdentifier: pid_t?)
    {
        self.operation = operation
        self.mutatesDesktop = mutatesDesktop
        self.clientProcessIdentifier = clientProcessIdentifier
        self.targetProcessIdentifier = targetProcessIdentifier
    }
}

/// One finished request from an authorized client: which operation, on which app or window, and how it ended.
///
/// It carries no payload, so typed text, clipboard contents and values never reach the embedder.
public struct PeekabooBridgeOperationRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// The operation finished, and a mutation's effect was confirmed.
        case completed
        /// A mutation was dispatched, or may have been, but its effect wasn't confirmed.
        case unknown
        /// The request was refused, or failed, before anything was dispatched.
        case refused
    }

    /// The socket peer that sent the request.
    public let clientProcessIdentifier: pid_t
    public let operation: PeekabooBridgeOperation
    /// Whether the operation can change the desktop, as its result contract says.
    public let mutatesDesktop: Bool
    /// The process the request targets, when it names one.
    public let targetProcessIdentifier: pid_t?
    /// The exact window the request targets, when it names one.
    public let targetWindowID: CGWindowID?
    public let outcome: Outcome

    public init(
        clientProcessIdentifier: pid_t,
        operation: PeekabooBridgeOperation,
        mutatesDesktop: Bool,
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?,
        outcome: Outcome)
    {
        self.clientProcessIdentifier = clientProcessIdentifier
        self.operation = operation
        self.mutatesDesktop = mutatesDesktop
        self.targetProcessIdentifier = targetProcessIdentifier
        self.targetWindowID = targetWindowID
        self.outcome = outcome
    }
}

@MainActor
extension PeekabooBridgeServer {
    /// Runs one routed request and reports it to the embedder once it has finished.
    ///
    /// Advisory only: the report never changes routing or the response, and requests from peers that fail
    /// authorization report nothing.
    func recordingOperation(
        _ plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        peer: PeekabooBridgePeer?,
        route: () async throws -> PeekabooBridgeHandledResponse) async throws -> PeekabooBridgeHandledResponse
    {
        guard let observer = self.operationObserver, let peer, (try? self.validatePeerAuthorization(peer)) != nil else {
            return try await route()
        }
        // Read before dispatch: a snapshot the request names can be gone afterward.
        let window = await self.requestTargetWindow(plan)
        let process = await self.requestTargetProcess(plan, window: window)
        func report(_ outcome: PeekabooBridgeOperationRecord.Outcome) {
            observer(.init(
                clientProcessIdentifier: peer.processIdentifier,
                operation: plan.request.operation,
                mutatesDesktop: plan.result.completion.mutatesDesktop,
                targetProcessIdentifier: process,
                targetWindowID: window?.1,
                outcome: outcome))
        }
        do {
            let handled = try await route()
            report(Self.recordedOutcome(handled.mutation?.outcome.state))
            return handled
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            report(envelope.operationMayHaveCompleted ? .unknown : .refused)
            throw envelope
        } catch {
            report(.unknown)
            throw error
        }
    }

    static func recordedOutcome(_ state: DesktopActionOutcome.State?) -> PeekabooBridgeOperationRecord.Outcome {
        switch state {
        case nil, .confirmedChange, .confirmedNoChange:
            .completed
        case .refused:
            .refused
        case .partial, .dispatchedUnverified, .suspectedNoop, .indeterminate:
            .unknown
        }
    }

    /// The process a request targets: its exact window's owner, its operation scope's process, or else any exact
    /// identity or target receipt in its payload, such as an app to activate or a status item's owner, or the owner
    /// of the window its snapshot captured.
    func requestTargetProcess(
        _ plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        window: (pid_t, CGWindowID)?) async -> pid_t?
    {
        if let window { return window.0 }
        if let process = plan.desktopOperationScope.processIdentity?.processIdentifier { return process }
        var snapshot: String?
        if let process = Self.referencedProcess(in: plan.request, depth: 0, snapshot: &snapshot) { return process }
        if let snapshot { return await self.snapshotWindow(snapshot)?.0 }
        return nil
    }

    /// The first exact process identity, window identity or target receipt within `value`, and its first snapshot ID.
    static func referencedProcess(in value: Any, depth: Int, snapshot: inout String?) -> pid_t? {
        switch value {
        case let identity as ApplicationProcessIdentity:
            return identity.processIdentifier
        case let identity as WindowMutationIdentity:
            return identity.ownerProcessIdentifier
        case let receipt as DesktopActionTargetReceipt:
            return receipt.processIdentifier
        default:
            break
        }
        guard depth < 6 else { return nil }
        for child in Mirror(reflecting: value).children {
            if snapshot == nil, child.label == "snapshotId" || child.label == "snapshot",
               let identifier = child.value as? String
            {
                snapshot = identifier
            }
            if let process = Self.referencedProcess(in: child.value, depth: depth + 1, snapshot: &snapshot) {
                return process
            }
        }
        return nil
    }

    /// Asks the embedder whether a request may run, before dispatch.
    func admissionRefusal(
        _ plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        peer: PeekabooBridgePeer?) async -> String?
    {
        guard let admission = self.operationAdmission else { return nil }
        let target = await self.requestTargetProcess(plan, window: await self.requestTargetWindow(plan))
        return admission(.init(
            operation: plan.request.operation,
            mutatesDesktop: plan.result.completion.mutatesDesktop,
            clientProcessIdentifier: peer?.processIdentifier,
            targetProcessIdentifier: target))
    }
}
