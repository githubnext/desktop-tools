import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeClipboardFilesWriteResult: Codable, Sendable {
    public let outcome: String
    public let native_outcome: DesktopActionOutcome
    public let clipboard_changed: Bool
    public let file_count: Int
    public let error: LiteralInsertError?
}

extension PeekabooBridgeClient {
    public func clipboardFilesWrite(_ paths: [String]) async throws -> PeekabooBridgeClipboardFilesWriteResult {
        switch try await self.send(.clipboardFilesWrite(paths)) {
        case let .clipboardFilesWrite(result): return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected clipboard files write response")
        }
    }
}

@MainActor
extension PeekabooBridgeServer {
    func handleClipboardFilesWrite(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        guard case let .clipboardFilesWrite(paths) = request else { throw Self.invalidRequest(for: request) }
        let files = try ClipboardFilesInput.validate(paths)
        return try await ClipboardPasteTransactionGate.withExclusiveTransaction {
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            let result: PeekabooBridgeClipboardFilesWriteResult
            do {
                let written = try self.literalInsertClipboard.setFilesActionResult(files)
                let native = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
                    written.outcome, operation: "Clipboard files write")
                result = .init(outcome: "completed", native_outcome: native,
                               clipboard_changed: true, file_count: files.files.count, error: nil)
            } catch let failure as DesktopActionFailure {
                let changed = failure.outcome.dispatchState.mutationDispatched
                result = .init(outcome: changed ? "unknown" : "refused", native_outcome: failure.outcome,
                    clipboard_changed: changed, file_count: files.files.count,
                    error: .init(code: failure.standardErrorCode?.rawValue ?? "CLIPBOARD_WRITE_FAILED",
                                 message: failure.message, hint: failure.hint))
            }
            // The signed global receipt binds result metadata, not a receiver's later use of the references.
            return .init(response: .clipboardFilesWrite(result), mutation: .init(
                outcome: .dispatchedUnverified(delivery: ClipboardMutationResultSemantics.delivery,
                                              evidence: .deliveryAccepted, unitCount: .one), target: .global))
        }
    }
}
