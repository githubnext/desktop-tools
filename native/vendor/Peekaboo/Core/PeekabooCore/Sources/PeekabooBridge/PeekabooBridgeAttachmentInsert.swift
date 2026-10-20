import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// One image, or file references, pasted into the snapshot's focused receiver through a temporary clipboard.
public struct PeekabooBridgeAttachmentInsertRequest: Codable, Sendable {
    public let snapshot: String
    public let image: Data?
    public let paths: [String]?
    /// Leaves the paste on the clipboard: no copy of the prior contents and no paste reservation.
    public let replace: Bool

    public init(snapshot: String, image: Data?, paths: [String]?, replace: Bool) {
        self.snapshot = snapshot; self.image = image; self.paths = paths; self.replace = replace
    }
}

extension PeekabooBridgeClient {
    public func attachmentInsert(
        snapshot: String, image: Data?, paths: [String]?, replace: Bool) async throws -> PeekabooBridgeLiteralInsertResult
    {
        switch try await self.send(.attachmentInsert(.init(snapshot: snapshot, image: image, paths: paths, replace: replace))) {
        case let .literalInsert(result): return result
        case let .error(error): throw error
        default: throw PeekabooBridgeErrorEnvelope(code: .internalError, message: "Unexpected attachment insertion response")
        }
    }
}

@MainActor
extension PeekabooBridgeServer {
    func handleAttachmentInsert(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        guard case let .attachmentInsert(payload) = request, (payload.image == nil) != (payload.paths == nil) else {
            throw Self.invalidRequest(for: request)
        }
        let attachment: AttachmentPastePayload
        if let data = payload.image {
            let decoding = Task.detached(priority: .userInitiated) { try ClipboardImageInput.validate(data) }
            attachment = try await .image(withTaskCancellationHandler {
                try await decoding.value
            } onCancel: {
                decoding.cancel()
            })
        } else {
            attachment = try .files(ClipboardFilesInput.validate(payload.paths ?? []))
        }
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        return try await self.handleGuardedPaste(snapshot: payload.snapshot) { target in
            guard let service = self.services.automation as? any AttachmentInsertServiceProtocol else { return nil }
            return try await service.attachmentInsert(
                attachment, replace: payload.replace, target: target, clipboard: self.literalInsertClipboard,
                checkActive: { try PeekabooBridgeRequestContext.checkRequestIsActive() })
        }
    }
}
