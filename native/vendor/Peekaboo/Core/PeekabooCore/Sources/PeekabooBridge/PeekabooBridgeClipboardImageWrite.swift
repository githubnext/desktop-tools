import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeClipboardImageWriteResult: Codable, Sendable {
    public let outcome: String
    public let native_outcome: DesktopActionOutcome
    public let clipboard_changed: Bool
    public let source: ClipboardImageContents.Source
    public let error: LiteralInsertError?
}

extension PeekabooBridgeClient {
    public func clipboardImageWrite(_ data: Data) async throws -> PeekabooBridgeClipboardImageWriteResult {
        switch try await self.send(.clipboardImageWrite(data)) {
        case let .clipboardImageWrite(result): return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected clipboard image write response")
        }
    }
}

@MainActor
extension PeekabooBridgeServer {
    func handleClipboardImageWrite(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        guard case let .clipboardImageWrite(data) = request else { throw Self.invalidRequest(for: request) }
        let decoding = Task.detached(priority: .userInitiated) { try ClipboardImageInput.validate(data) }
        let image = try await withTaskCancellationHandler {
            try await decoding.value
        } onCancel: {
            decoding.cancel()
        }
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        return try await ClipboardPasteTransactionGate.withExclusiveTransaction {
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            let result: PeekabooBridgeClipboardImageWriteResult
            do {
                let written = try self.literalInsertClipboard.setActionResult(.init(representations: [
                    .init(utiIdentifier: image.source.uti, data: image.data),
                ]))
                let native = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
                    written.outcome, operation: "Clipboard image write")
                result = .init(outcome: "completed", native_outcome: native,
                               clipboard_changed: true, source: image.source, error: nil)
            } catch let failure as DesktopActionFailure {
                let changed = failure.outcome.dispatchState.mutationDispatched
                result = .init(outcome: changed ? "unknown" : "refused", native_outcome: failure.outcome,
                    clipboard_changed: changed, source: image.source,
                    error: .init(code: failure.standardErrorCode?.rawValue ?? "CLIPBOARD_WRITE_FAILED",
                                 message: failure.message, hint: failure.hint))
            }
            // The existing signed global receipt binds the content-free result, not image bytes.
            return .init(response: .clipboardImageWrite(result), mutation: .init(
                outcome: .dispatchedUnverified(delivery: ClipboardMutationResultSemantics.delivery,
                                              evidence: .deliveryAccepted, unitCount: .one), target: .global))
        }
    }
}
