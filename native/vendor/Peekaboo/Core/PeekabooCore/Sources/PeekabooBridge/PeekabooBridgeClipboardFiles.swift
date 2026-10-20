import Foundation
import PeekabooAutomationKit

extension PeekabooBridgeClient {
    public func clipboardFilesRead() async throws -> ClipboardFilesContents {
        switch try await self.send(.clipboardFilesRead) {
        case let .clipboardFiles(result): return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected clipboard files response")
        }
    }
}

@MainActor
extension PeekabooBridgeServer {
    func handleClipboardFilesRead() async throws -> PeekabooBridgeHandledResponse {
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        let result = try self.literalInsertClipboard.readFiles()
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        return .init(response: .clipboardFiles(result))
    }
}
