import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeClipboardTextWriteResult: Codable, Sendable {
    public let outcome: String
    public let native_outcome: DesktopActionOutcome
    public let clipboard_changed: Bool
    public let error: LiteralInsertError?
}

extension PeekabooBridgeClient {
    public func clipboardTextRead() async throws -> ClipboardTextContents {
        switch try await self.send(.clipboardTextRead) {
        case let .clipboardText(result): return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected clipboard read response")
        }
    }

    public func clipboardTextWrite(_ text: String) async throws -> PeekabooBridgeClipboardTextWriteResult {
        switch try await self.send(.clipboardTextWrite(text)) {
        case let .clipboardTextWrite(result): return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected clipboard write response")
        }
    }
}

@MainActor
extension PeekabooBridgeServer {
    func handleClipboardTextRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        switch request {
        case .clipboardTextRead:
            // Reading never consumes or clears an unresolved paste reservation.
            return try .init(response: .clipboardText(self.literalInsertClipboard.readPlainText()))
        case let .clipboardTextWrite(text):
            guard text.utf16.count <= 8192 else {
                throw DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest,
                    message: "Clipboard text must contain at most 8192 UTF-16 code units.")
            }
            return try await ClipboardPasteTransactionGate.withExclusiveTransaction {
                try PeekabooBridgeRequestContext.checkRequestIsActive()
                let result: PeekabooBridgeClipboardTextWriteResult
                do {
                    let written = try self.literalInsertClipboard.setActionResult(.init(
                        representations: ClipboardWriteRequest.textRepresentations(from: Data(text.utf8))))
                    let native = try ClipboardMutationResultSemantics.requireSuccessfulOutcome(
                        written.outcome, operation: "Clipboard text write")
                    result = .init(outcome: "completed", native_outcome: native, clipboard_changed: true, error: nil)
                } catch let failure as DesktopActionFailure {
                    let changed = failure.outcome.dispatchState.mutationDispatched
                    result = .init(outcome: changed ? "unknown" : "refused", native_outcome: failure.outcome,
                        clipboard_changed: changed,
                        error: .init(code: failure.standardErrorCode?.rawValue ?? "CLIPBOARD_WRITE_FAILED",
                                     message: failure.message, hint: failure.hint))
                }
                // The signed global receipt binds the content-free native result, not the clipboard payload.
                return .init(response: .clipboardTextWrite(result), mutation: .init(
                    outcome: .dispatchedUnverified(delivery: ClipboardMutationResultSemantics.delivery,
                                                  evidence: .deliveryAccepted, unitCount: .one), target: .global))
            }
        default:
            throw Self.invalidRequest(for: request)
        }
    }
}
