import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

private struct DialogRequest: Decodable {
	enum Operation: String, Decodable {
		case dialog
		case answer = "dialog-answer"
	}
	let op: Operation
	let target: ManagementTarget
	let button: String?
	let field: Int?
	let text: String?
	let path: String?
}

private struct DialogError: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

private struct DialogMessage: Encodable {
	let code: String
	let message: String
	let hint: String?
}

private struct DialogListing: Encodable {
	struct Dialog: Encodable {
		let title: String
		let role: String
		let subrole: String?
		let is_file_dialog: Bool
		let bounds: Bounds
	}
	struct Button: Encodable {
		let title: String
		let is_enabled: Bool
		let is_default: Bool
	}
	struct Field: Encodable {
		let index: Int
		let title: String?
		let value: String?
		let placeholder: String?
		let is_enabled: Bool
	}
	struct Other: Encodable {
		let role: String
		let title: String?
		let value: String?
	}
	let target: ManagementTarget
	let application_name: String
	let window_title: String
	let dialog: Dialog
	let buttons: [Button]
	let text_fields: [Field]
	let static_texts: [String]
	let other_elements: [Other]
}

private struct DialogResult: Encodable {
	var outcome = "refused"
	let action = "dialog"
	var button: String?
	var field: Int?
	var path: String?
	var native_outcome: DesktopActionOutcome?
	var details: [String: String]?
	var requires_fresh_observation = false
	var message: String?
	var error: DialogMessage?
}

private struct DialogReply<T: Encodable>: Encodable {
	let success = true
	let data: T
	let target_receipt: Receipt?
}

private enum DialogTarget {
	case application(ApplicationProcessIdentity)
	case window(WindowMutationIdentity)

	var process: ApplicationProcessIdentity {
		switch self {
		case let .application(process): process
		case let .window(window): window.processIdentity
		}
	}

	var selector: DialogTargetSelector {
		get throws {
			switch self {
			case let .application(process): try DialogTargetSelector(processIdentifier: process.processIdentifier)
			case let .window(window):
				try DialogTargetSelector(processIdentifier: window.ownerProcessIdentifier, windowID: window.windowID)
			}
		}
	}

	/// The resolved dialog window must be the observed generation and, for a window target, its exact window and bounds.
	func matches(_ resolved: UIAutomationTarget.ExactWindow) -> Bool {
		switch self {
		case let .application(process):
			resolved.identity.processIdentity == process
		case let .window(window):
			resolved.identity.hasSameStableReceipt(as: window) && resolved.bounds == window.capturedBounds
		}
	}

	func matches(_ receipt: DesktopActionTargetReceipt?) -> Bool {
		guard let receipt, receipt.processIdentifier == process.processIdentifier,
			receipt.processStartIdentity == process.processStartIdentity
		else { return false }
		if case let .window(window) = self { return receipt.windowID == window.windowID }
		return receipt.windowID != nil
	}
}

/// Normalization Peekaboo applies when it resolves a prepared button title; only an exact, unique title may pass through it.
private func normalizedTitle(_ title: String) -> String {
	title.trimmingCharacters(in: .whitespacesAndNewlines)
		.replacingOccurrences(of: "…", with: "")
		.replacingOccurrences(of: "...", with: "")
		.lowercased()
}

func nativeDialog(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async throws -> Data {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		guard data.count + chunk.count <= 65_536 else { throw DialogError("The dialog request exceeds 64 KiB.") }
		data.append(chunk)
	}
	let request = try JSONDecoder().decode(DialogRequest.self, from: data)
	if request.op == .dialog {
		guard request.button == nil, request.field == nil, request.text == nil, request.path == nil else {
			throw DialogError("Listing a dialog takes only a target.")
		}
		let target = try dialogTarget(request.target)
		let listing = try await readDialog(client, handshake: handshake, target: target)
		return try JSONEncoder().encode(DialogReply(data: listing.0, target_receipt: listing.1))
	}
	return try await answerDialog(client, handshake: handshake, request: request)
}

private func dialogTarget(_ target: ManagementTarget) throws -> DialogTarget {
	if target.window_id == nil, target.bounds == nil, target.is_minimized == nil {
		return .application(try target.processIdentity())
	}
	return .window(try target.windowIdentity())
}

private func requireOperations(_ handshake: PeekabooBridgeHandshakeResponse, _ required: [PeekabooBridgeOperation]) throws {
	let enabled = handshake.enabledOperations ?? handshake.supportedOperations
	guard required.allSatisfy({ handshake.supportedOperations.contains($0) && enabled.contains($0) }) else {
		throw DialogError("The desktop runtime does not support exact dialog operations. Update the runtime before acting.")
	}
}

private func readDialog(
	_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse, target: DialogTarget
) async throws -> (DialogListing, Receipt, DialogElements) {
	try requireOperations(handshake, [.targetedDialogListElements])
	let elements = try await client.targetedDialogListElements(target: target.selector)
	guard let resolved = elements.resolvedTarget, target.matches(resolved.target) else {
		throw DialogError("The dialog was not resolved to the observed application generation and window. Refresh desktop_apps or desktop_windows and list the dialog again.")
	}
	let identity = resolved.target.identity
	let info = elements.dialogInfo
	let listing = DialogListing(
		target: ManagementTarget(window: identity, bounds: resolved.target.bounds),
		application_name: resolved.applicationName,
		window_title: resolved.windowTitle,
		dialog: .init(title: info.title, role: info.role, subrole: info.subrole, is_file_dialog: info.isFileDialog, bounds: Bounds(info.bounds)),
		buttons: elements.buttons.map { .init(title: $0.title, is_enabled: $0.isEnabled, is_default: $0.isDefault) },
		text_fields: elements.textFields.map {
			.init(index: $0.index, title: $0.title, value: $0.value, placeholder: $0.placeholder, is_enabled: $0.isEnabled)
		},
		static_texts: elements.staticTexts,
		other_elements: elements.otherElements.map { .init(role: $0.role, title: $0.title, value: $0.value) }
	)
	let receipt = Receipt(pid: identity.ownerProcessIdentifier, window_id: identity.windowID,
		process_start_identity_decimal: String(identity.ownerProcessStartIdentity))
	return (listing, receipt, elements)
}

private func answerDialog(
	_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse, request: DialogRequest
) async throws -> Data {
	var result = DialogResult(button: request.button, field: request.field, path: request.path)
	var receipt: Receipt?
	var target: DialogTarget?
	var invoked = false
	do {
		let answers = [request.button != nil, request.field != nil || request.text != nil, request.path != nil]
		guard answers.filter({ $0 }).count == 1, (request.field == nil) == (request.text == nil) else {
			throw DialogError("Answer a dialog with exactly one button title, one field index and its text, or one path.")
		}
		let resolvedTarget = try dialogTarget(request.target)
		target = resolvedTarget
		if let button = request.button {
			guard !button.isEmpty, button.utf16.count <= 512 else { throw DialogError("Use one exact button title of at most 512 UTF-16 code units.") }
			try requireOperations(handshake, [.targetedDialogListElements, .prepareDialogAction, .exactDialogClickButton])
		} else if let path = request.path {
			guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
				throw DialogError("Use one absolute path of at most 4096 bytes.")
			}
			try requireOperations(handshake, [.targetedDialogListElements, .exactFileDialogPath])
		} else {
			guard let field = request.field, (0...1000).contains(field), let text = request.text, text.utf16.count <= 8192 else {
				throw DialogError("Use a listed field index and at most 8192 UTF-16 code units of text.")
			}
			try requireOperations(handshake, [.targetedDialogListElements, .exactDialogEnterText])
		}
		let session = CGSessionCopyCurrentDictionary() as NSDictionary?
		if session?["CGSSessionScreenIsLocked"] as? Bool == true {
			throw DesktopActionFailure.preDispatchRefusal(
				reason: .targetUnavailable, message: "The macOS GUI session is locked. No dialog answer was dispatched.",
				hint: "Unlock the active user session, then list the dialog again."
			)
		}
		let process = resolvedTarget.process
		let inventory = try await client.listApplicationMutationInventory()
		guard let preflight = await client.lastOperationReceipt(),
			preflight.payload.operation == PeekabooBridgeRequest.listApplicationMutationInventory.operation,
			inventory.items.contains(where: { $0.processIdentity == process })
		else { throw DialogError("The observed application generation could not be attested before answering the dialog. Refresh desktop_apps.") }
		// A fresh read binds the requested control to the exact dialog before anything is dispatched.
		let (_, _, elements) = try await readDialog(client, handshake: handshake, target: resolvedTarget)
		if let button = request.button {
			let exact = elements.buttons.filter { $0.title == button }
			let similar = elements.buttons.filter { normalizedTitle($0.title) == normalizedTitle(button) }
			let available = elements.buttons.map(\.title)
			guard exact.count == 1, similar.count == 1, normalizedTitle(button) != "default" else {
				throw DesktopActionFailure.preDispatchRefusal(
					reason: .targetUnavailable,
					message: exact.isEmpty
						? "No dialog button has exactly the title \(String(reflecting: button))."
						: "The dialog button title \(String(reflecting: button)) is not unique.",
					hint: "Available buttons: \(available.map { String(reflecting: $0) }.joined(separator: ", ")). Use one exact, unique title."
				)
			}
			guard exact[0].isEnabled else {
				throw DesktopActionFailure.preDispatchRefusal(
					reason: .targetUnavailable, message: "The dialog button \(String(reflecting: button)) is disabled.",
					hint: "List the dialog again after its state changes."
				)
			}
			let prepared = try await client.prepareDialogAction(DialogActionPreparationRequest(
				target: resolvedTarget.selector, kind: .clickButton, buttonText: button
			))
			guard prepared.kind == .clickButton, resolvedTarget.matches(prepared.target) else {
				throw DialogError("The prepared dialog action resolved a different application generation or window. List the dialog again.")
			}
			try Task.checkCancellation()
			invoked = true
			let action = try await client.performPreparedDialogAction(prepared)
			result.native_outcome = action.outcome
			result.details = action.details
			guard let signed = await client.lastOperationReceipt(), signed.payload.operation == .exactDialogClickButton,
				let outcome = action.outcome, signed.payload.outcome?.outcome == outcome,
				case let .window(identity) = signed.payload.target, identity.hasSameStableReceipt(as: prepared.target.identity)
			else { throw DialogError("The dialog button press returned without its matching signed window receipt and outcome.") }
			receipt = Receipt(pid: identity.ownerProcessIdentifier, window_id: identity.windowID,
				process_start_identity_decimal: String(identity.ownerProcessStartIdentity))
			result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
			result.outcome = outcome.state == .confirmedChange ? "completed" : "unknown"
		} else if let path = request.path {
			guard elements.dialogInfo.isFileDialog else {
				throw DesktopActionFailure.preDispatchRefusal(
					reason: .operationUnsupported, message: "The dialog is not an Open or Save panel, so it takes no path.",
					hint: "Answer it with a button title, or a field index and text."
				)
			}
			try Task.checkCancellation()
			invoked = true
			// The host activates the panel's app and uses Go to Folder or the panel's path field, then reads the result back.
			let action = try await client.exactFileDialogPath(FileDialogPathRequest(target: resolvedTarget.selector, path: path))
			result.native_outcome = action.outcome
			result.details = action.details
			guard let signed = await client.lastOperationReceipt(), signed.payload.operation == .exactFileDialogPath,
				let outcome = action.outcome, signed.payload.outcome?.outcome == outcome,
				resolvedTarget.matches(action.targetReceipt),
				case let .window(identity) = signed.payload.target, identity.processIdentity == process,
				identity.windowID == action.targetReceipt?.windowID
			else {
				throw DialogError("The dialog path entry returned without its matching signed process-generation receipt and outcome.")
			}
			receipt = Receipt(pid: identity.ownerProcessIdentifier, window_id: identity.windowID,
				process_start_identity_decimal: String(identity.ownerProcessStartIdentity))
			result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
			if outcome.state == .confirmedChange {
				result.outcome = "completed"
			} else {
				result.outcome = "unknown"
				result.error = DialogMessage(
					code: "DESKTOP_ACTION_UNVERIFIED",
					message: "The path was entered, but the panel didn't read back the chosen folder\(action.details["filename"] == nil ? "" : " and name").",
					hint: "List the dialog to check its folder and name before pressing its default button; do not blindly repeat the path."
				)
			}
		} else {
			let field = request.field!
			let fields = elements.textFields.filter { $0.index == field }
			guard fields.count == 1, elements.textFields.count == Set(elements.textFields.map(\.index)).count else {
				throw DesktopActionFailure.preDispatchRefusal(
					reason: .targetUnavailable, message: "The dialog has no text field at index \(field).",
					hint: "List the dialog and choose one current text field index."
				)
			}
			guard fields[0].isEnabled else {
				throw DesktopActionFailure.preDispatchRefusal(
					reason: .targetUnavailable, message: "The dialog text field at index \(field) is disabled.",
					hint: "List the dialog again after its state changes."
				)
			}
			try Task.checkCancellation()
			invoked = true
			let action = try await client.exactDialogEnterText(DialogInputExecutionRequest(
				target: resolvedTarget.selector, text: request.text!, fieldIdentifier: String(field), clearExisting: true
			))
			result.native_outcome = action.outcome
			result.details = action.details
			guard let signed = await client.lastOperationReceipt(), signed.payload.operation == .exactDialogEnterText,
				let outcome = action.outcome, signed.payload.outcome?.outcome == outcome,
				resolvedTarget.matches(action.targetReceipt),
				case let .window(identity) = signed.payload.target, identity.processIdentity == process,
				identity.windowID == action.targetReceipt?.windowID
			else {
				throw DialogError("The dialog text entry returned without its matching signed process-generation receipt and outcome.")
			}
			receipt = Receipt(pid: identity.ownerProcessIdentifier, window_id: identity.windowID,
				process_start_identity_decimal: String(identity.ownerProcessStartIdentity))
			result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
			// The native service reads the retained field back and fails unless its value matches the request.
			switch outcome.state {
			case .confirmedNoChange, .confirmedChange: result.outcome = "completed"
			case .dispatchedUnverified where outcome.evidence == .deliveryAccepted: result.outcome = "completed"
			case .refused: result.outcome = "refused"
			default: result.outcome = "unknown"
			}
		}
	} catch let failure as DesktopActionFailure {
		let dispatched = failure.outcome.dispatchState.mutationDispatched
		result.outcome = dispatched ? "unknown" : "refused"
		result.native_outcome = failure.outcome
		if let target, let attributed = failure.targetReceipt, target.matches(attributed) {
			receipt = Receipt(pid: attributed.processIdentifier, window_id: attributed.windowID,
				process_start_identity_decimal: String(attributed.processStartIdentity))
		}
		result.requires_fresh_observation = dispatched || failure.outcome.escalation == .refreshTarget
		result.error = DialogMessage(code: failure.standardErrorCode?.rawValue ?? "DESKTOP_ACTION_FAILED", message: failure.message,
			hint: dispatched ? "The dialog may already have been answered. List it again or refresh desktop_windows; do not blindly repeat the answer." : failure.hint)
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		result.requires_fresh_observation = invoked
		result.error = DialogMessage(
			code: (error as? PeekabooBridgeErrorEnvelope)?.code.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: error.localizedDescription,
			hint: invoked ? "The dialog may already have been answered. List it again or refresh desktop_windows; do not blindly repeat the answer." : nil
		)
	}
	return try JSONEncoder().encode(DialogReply(data: result, target_receipt: receipt))
}
