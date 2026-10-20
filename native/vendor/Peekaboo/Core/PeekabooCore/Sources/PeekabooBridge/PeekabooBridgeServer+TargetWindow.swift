import CoreGraphics
import Foundation
import PeekabooAutomationKit

/// The exact window an authorized request is about to observe or act on.
public struct PeekabooBridgeTargetWindow: Sendable, Equatable {
    /// The socket peer that sent the request.
    public let clientProcessIdentifier: pid_t
    /// The process that owns the window.
    public let processIdentifier: pid_t
    public let windowID: CGWindowID

    public init(clientProcessIdentifier: pid_t, processIdentifier: pid_t, windowID: CGWindowID) {
        self.clientProcessIdentifier = clientProcessIdentifier
        self.processIdentifier = processIdentifier
        self.windowID = windowID
    }
}

@MainActor
extension PeekabooBridgeServer {
    /// Reports the request's exact window to the embedder before dispatch.
    ///
    /// Advisory only: the report never changes target checks, routing, or outcomes, and requests without one exact
    /// window (screens, apps, menus, clipboard) report nothing.
    func reportTargetWindow(
        _ plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        peer: PeekabooBridgePeer?) async
    {
        guard let observer = self.targetWindowObserver, let peer,
              let (processIdentifier, windowID) = await self.requestTargetWindow(plan)
        else { return }
        observer(.init(
            clientProcessIdentifier: peer.processIdentifier,
            processIdentifier: processIdentifier,
            windowID: windowID))
    }

    /// The one exact window a request names, directly, through its snapshot, or through its operation scope.
    func requestTargetWindow(
        _ plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) async -> (pid_t, CGWindowID)?
    {
        switch plan.request {
        case let .desktopObservation(request):
            switch request.target {
            case let .pid(pid, window: .id(windowID)):
                (pid, windowID)
            case let .windowID(windowID):
                self.windowOwnerProcessIdentifierProvider(windowID).map { ($0, windowID) }
            default:
                nil
            }
        case let .beginSnapshotMutation(payload):
            await self.snapshotWindow(payload.snapshotId)
        case let .literalInsert(payload):
            await self.snapshotWindow(payload.snapshot)
        case let .attachmentInsert(payload):
            await self.snapshotWindow(payload.snapshot)
        default:
            if case let .window(identity) = plan.desktopOperationScope,
               let windowID = CGWindowID(exactly: identity.windowID)
            {
                (identity.ownerProcessIdentifier, windowID)
            } else {
                nil
            }
        }
    }

    func snapshotWindow(_ snapshotId: String) async -> (pid_t, CGWindowID)? {
        guard let context = try? await self.services.snapshots.getDetectionResult(snapshotId: snapshotId)?
            .metadata.windowContext,
            let processIdentifier = context.applicationProcessId,
            let windowID = context.windowID.flatMap(CGWindowID.init(exactly:))
        else { return nil }
        return (processIdentifier, windowID)
    }
}
