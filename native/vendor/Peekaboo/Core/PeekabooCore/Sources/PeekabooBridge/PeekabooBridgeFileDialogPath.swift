import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    /// Chooses one path in one exact Open or Save panel in the Bridge host, without pressing its default button.
    public func exactFileDialogPath(_ request: FileDialogPathRequest) async throws -> DialogActionResult {
        let reply = try await self.sendCarryingActionOutcome(.exactFileDialogPath(request))
        switch reply.response {
        case let .dialogResult(result):
            guard result.success,
                  result.action == .handleFileDialog,
                  let outcome = result.outcome,
                  outcome.state == .confirmedChange || outcome.state == .dispatchedUnverified,
                  let targetReceipt = result.targetReceipt,
                  request.target.processIdentifier.map({ $0 == targetReceipt.processIdentifier }) ?? true,
                  request.target.windowID.map({ $0 == targetReceipt.windowID }) ?? true
            else {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    evidence: .completionUnknown,
                    unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                    message: "Bridge returned invalid exact file-dialog path evidence.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            let routedOutcome = outcome.routed(to: .bridge)
            if let projected = reply.outcome?.outcome, projected != routedOutcome {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "Bridge exact file-dialog path carried contradictory canonical outcomes.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            return DialogActionResult(
                success: result.success,
                action: result.action,
                details: result.details,
                outcome: routedOutcome,
                targetReceipt: targetReceipt,
                targetWindowIdentity: result.targetWindowIdentity,
                targetWindowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement,
                resolvedTarget: result.resolvedTarget)
        case let .error(envelope):
            if let failure = envelope.desktopActionFailure ?? reply.outcome.flatMap({ projection in
                DesktopActionFailure(
                    outcome: projection.outcome,
                    message: envelope.message,
                    hint: envelope.actionFailureHint,
                    causeDescription: envelope.actionFailureCauseDescription ?? envelope.details)
            }) {
                throw failure.routed(to: .bridge)
            }
            throw envelope
        default:
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                message: "Bridge returned an unexpected exact file-dialog path response.",
                hint: "Observe the dialog before retrying and update the runtime host.")
        }
    }
}
