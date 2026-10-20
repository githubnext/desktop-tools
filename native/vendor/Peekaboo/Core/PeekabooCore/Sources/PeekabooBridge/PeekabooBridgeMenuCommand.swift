import Foundation
import PeekabooAutomationKit

extension PeekabooBridgeClient {
    public func menuCommand(_ request: MenuCommandRequest) async throws -> UIAutomationActionResult<Void> {
        try await self.actionResult(for: .menuCommand(request), expectedResponse: "literal menu command",
                                    requiresTargetIdentity: true) { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }
}
