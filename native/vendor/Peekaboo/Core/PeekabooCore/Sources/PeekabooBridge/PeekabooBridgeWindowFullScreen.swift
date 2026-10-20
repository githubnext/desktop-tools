import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeWindowFullScreenRequest: Codable, Sendable {
    public let target: WindowTarget
    public let expectedIdentity: WindowMutationIdentity?
    public let fullScreen: Bool

    public init(target: WindowTarget, expectedIdentity: WindowMutationIdentity? = nil, fullScreen: Bool) {
        self.target = target
        self.expectedIdentity = expectedIdentity
        self.fullScreen = fullScreen
    }
}

extension PeekabooBridgeClient {
    /// Enters or leaves native full screen for one exact window in the Bridge host.
    public func setWindowFullScreenResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        fullScreen: Bool) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await self.windowMutationOutcome(.setWindowFullScreen(
            PeekabooBridgeWindowFullScreenRequest(
                target: target,
                expectedIdentity: expectedIdentity,
                fullScreen: fullScreen)))
        return DesktopActionResult(outcome: outcome)
    }
}
