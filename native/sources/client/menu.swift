import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

private struct MenuCommandInput: Decodable {
	let target: ManagementTarget
	let path: [String]
}

private struct MenuCommandError: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

private struct MenuCommandMessage: Encodable {
	let code: String
	let message: String
	let hint: String?
}

private struct MenuCommandResult: Encodable {
	var outcome = "refused"
	let action = "menu"
	var native_outcome: DesktopActionOutcome?
	var requires_fresh_observation = false
	var error: MenuCommandMessage?
}

private struct MenuCommandReply: Encodable {
	let success = true
	let data: MenuCommandResult
	let target_receipt: Receipt?
}

func nativeMenuCommand(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async throws -> Data {
	var result = MenuCommandResult()
	var receipt: Receipt?
	var process: ApplicationProcessIdentity?
	var invoked = false
	do {
		var data = Data()
		while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
			guard data.count + chunk.count <= 4096 else { throw MenuCommandError("Menu request exceeds the 4096-byte limit.") }
			data.append(chunk)
		}
		let input = try JSONDecoder().decode(MenuCommandInput.self, from: data)
		guard input.target.window_id == nil, input.target.bounds == nil, input.target.is_minimized == nil else {
			throw MenuCommandError("Menu commands require only the application target from desktop_apps.")
		}
		let identity = try input.target.processIdentity()
		process = identity
		let request = try MenuCommandRequest(expectedIdentity: identity, path: input.path)
		guard handshake.supportedOperations.contains(.menuCommand),
			(handshake.enabledOperations ?? handshake.supportedOperations).contains(.menuCommand)
		else { throw MenuCommandError("The native runtime does not support exact literal menu commands. Update the desktop runtime before acting.") }
		let session = CGSessionCopyCurrentDictionary() as NSDictionary?
		if session?["CGSSessionScreenIsLocked"] as? Bool == true {
			throw DesktopActionFailure.preDispatchRefusal(
				reason: .targetUnavailable, message: "The macOS GUI session is locked. No menu command was dispatched.",
				hint: "Unlock the active user session and refresh the application and its menus."
			)
		}
		let inventory = try await client.listApplicationMutationInventory()
		guard let preflight = await client.lastOperationReceipt(),
			preflight.payload.operation == PeekabooBridgeRequest.listApplicationMutationInventory.operation,
			inventory.items.contains(where: { $0.processIdentity == identity })
		else { throw MenuCommandError("The observed application generation could not be attested before the menu command.") }
		try Task.checkCancellation()
		invoked = true
		let action = try await client.menuCommand(request)
		result.native_outcome = action.outcome
		guard let signed = await client.lastOperationReceipt(), signed.payload.operation == .menuCommand,
			let outcome = action.outcome, signed.payload.outcome?.outcome == outcome,
			action.targetIdentity?.processIdentity == identity, action.targetIdentity?.exactWindow == nil,
			case let .process(verified) = signed.payload.target, verified == identity
		else { throw MenuCommandError("The menu command returned without its matching signed application receipt and outcome.") }
		receipt = Receipt(pid: identity.processIdentifier, window_id: nil, process_start_identity_decimal: String(identity.processStartIdentity))
		result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
		switch outcome.state {
		case .refused:
			result.outcome = "refused"
		case .dispatchedUnverified where outcome.evidence == .deliveryAccepted:
			result.outcome = "completed"
		default:
			result.outcome = "unknown"
		}
	} catch let failure as DesktopActionFailure {
		result.native_outcome = failure.outcome
		result.outcome = failure.outcome.dispatchState.mutationDispatched ? "unknown" : "refused"
		if let process, failure.targetReceipt == process.actionTargetReceipt {
			receipt = Receipt(pid: process.processIdentifier, window_id: nil, process_start_identity_decimal: String(process.processStartIdentity))
		}
		result.requires_fresh_observation = failure.outcome.dispatchState.mutationDispatched || failure.outcome.escalation == .refreshTarget
		result.error = MenuCommandMessage(code: failure.standardErrorCode?.rawValue ?? "DESKTOP_ACTION_FAILED", message: failure.message, hint: failure.hint)
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		result.requires_fresh_observation = invoked
		result.error = MenuCommandMessage(
			code: (error as? PeekabooBridgeErrorEnvelope)?.code.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: error.localizedDescription,
			hint: invoked ? "Observe the application; the menu command may already have happened. Do not blindly repeat it." : nil
		)
	}
	return try JSONEncoder().encode(MenuCommandReply(data: result, target_receipt: receipt))
}
