import Foundation
import PeekabooAutomationKit

extension PeekabooBridgeClient {
    public func clipboardImageRead() async throws -> ClipboardImageContents {
        switch try await self.send(.clipboardImageRead) {
        case let .clipboardImage(result): return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected clipboard image response")
        }
    }

    /// Reads the clipboard image as `clipboardImageRead` does, plus its original bytes.
    public func clipboardImageExport() async throws -> ClipboardImageContents {
        switch try await self.send(.clipboardImageExport) {
        case let .clipboardImage(result):
            guard !result.present || result.original?.count == result.source?.bytes else {
                throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "The clipboard image export has no complete original")
            }
            return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected clipboard image response")
        }
    }
}

@MainActor
extension PeekabooBridgeServer {
    func handleClipboardImageRead(includingOriginal: Bool = false) async throws -> PeekabooBridgeHandledResponse {
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        let result = try await self.literalInsertClipboard.readImage(includingOriginal: includingOriginal)
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        return .init(response: .clipboardImage(result))
    }
}
