import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public typealias PeekabooBridgeLiteralInsertResult = LiteralInsertResult

public struct PeekabooBridgeLiteralInsertRequest: Codable, Sendable {
    public let snapshot: String
    public let text: String

    public init(snapshot: String, text: String) { self.snapshot = snapshot; self.text = text }
}

extension PeekabooBridgeClient {
    public func literalInsert(snapshot: String, text: String) async throws -> PeekabooBridgeLiteralInsertResult {
        guard case let .literalInsert(result) = try await self.send(.literalInsert(.init(snapshot: snapshot, text: text))) else {
            throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected literal insertion response")
        }
        return result
    }
}

@MainActor
extension PeekabooBridgeServer {
    func handleLiteralInsert(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        guard case let .literalInsert(payload) = request, !payload.text.isEmpty, payload.text.utf16.count <= 8192 else {
            throw DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable,
                message: "Inspect an exact window with a readable focused text control before inserting text.")
        }
        return try await self.handleGuardedPaste(snapshot: payload.snapshot) { target in
            guard let service = self.services.automation as? any LiteralInsertServiceProtocol else { return nil }
            return try await service.literalInsert(
                text: payload.text, target: target, clipboard: self.literalInsertClipboard,
                checkActive: { try PeekabooBridgeRequestContext.checkRequestIsActive() })
        }
    }

    /// Runs one GUI-owned paste into the snapshot's exact focused receiver, holding the snapshot lease throughout.
    /// `paste` returns nil when this host's automation service can't paste.
    func handleGuardedPaste(
        snapshot: String,
        paste: (UIAutomationTarget.ExactWindow) async throws -> LiteralInsertResult?) async throws
        -> PeekabooBridgeHandledResponse
    {
        try await ClipboardPasteTransactionGate.withExclusiveTransaction {
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            guard !snapshot.isEmpty, snapshot.utf16.count <= 256,
                  try await self.services.snapshots.ownsSnapshot(snapshotId: snapshot),
                  let detection = try await self.services.snapshots.getDetectionResult(snapshotId: snapshot),
                  let context = detection.metadata.windowContext,
                  let identity = context.windowMutationIdentity,
                  let bounds = context.windowBounds,
                  context.windowID == identity.windowID,
                  context.applicationProcessId == identity.ownerProcessIdentifier,
                  let focused = context.focusedElement
            else {
                throw DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable,
                    message: "Inspect an exact window with a readable focused text control before inserting text.")
            }
            let lease = try await self.services.snapshots.beginSnapshotMutation(snapshotId: snapshot)
            var result: LiteralInsertResult
            do {
                guard let pasted = try await paste(.init(identity: identity, bounds: bounds, focusedElement: focused)) else {
                    throw DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable,
                        message: "This host's automation service can't paste into an exact receiver.")
                }
                result = pasted
            } catch {
                try? await self.services.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: true)
                throw error
            }
            do {
                try await self.services.snapshots.finishSnapshotMutation(lease,
                    requiresFreshObservation: result.requires_fresh_observation)
            } catch {
                result.requires_fresh_observation = true
                if result.error == nil {
                    result.error = .init(code: "SNAPSHOT_FINISH_FAILED",
                        message: "The insertion result is retained; inspect again before another input.")
                }
            }
            // The signed global receipt binds this GUI-owned clipboard transaction and its nested exact target/result.
            return .init(response: .literalInsert(result), mutation: .init(
                outcome: .dispatchedUnverified(delivery: ClipboardMutationResultSemantics.delivery,
                                              evidence: .deliveryAccepted, unitCount: .one), target: .global))
        }
    }
}
