import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

/// A request to fill the focused secure text field from a named Keychain item or with text the agent supplies.
private struct FillRequest: Decodable {
	let snapshot: String
	let element: String
	/// A generic password, by the service it is saved under.
	let service: String?
	/// An internet password, by its server; it fills only a field in a web page on that server.
	let server: String?
	let account: String?
	let text: String?

	func secret() throws -> PeekabooBridgeSecureTextFillRequest.Secret {
		guard !snapshot.isEmpty, snapshot.utf16.count <= 256, !element.isEmpty, element.utf16.count <= 256 else {
			throw ActionError("Use a snapshot ID and an element ID from desktop_inspect.")
		}
		switch (service, server, text) {
		case let (service?, nil, nil) where !service.isEmpty:
			return .keychain(.init(kind: .generic, name: service, account: account))
		case let (nil, server?, nil) where !server.isEmpty:
			return .keychain(.init(kind: .internet, name: server.lowercased(), account: account))
		case let (nil, nil, text?) where account == nil:
			return .text(text)
		default:
			throw ActionError("Name one Keychain item by service or server, with an optional account, or supply text; not more than one.")
		}
	}
}

private struct FillResult: Encodable {
	var outcome = "refused"
	let action = "fill"
	let snapshot_id: String
	var requires_fresh_observation = false
	var error: FillMessage?
}

private struct FillMessage: Encodable {
	let code: String
	let message: String
	var hint: String?
}

private struct FillReply: Encodable {
	let success = true
	let data: FillResult
	let target_receipt: Receipt?
}

/// How long a fill may wait, including for the user to answer a Keychain prompt or a confirmation, which the host
/// gives up on after a minute.
private let fillTimeout: TimeInterval = 90

/// Fills the snapshot's focused secure text field. The host reads the secret or asks the user, types it, and confirms
/// it only by counting the field's mask characters. Nothing here returns or records the secret or its length.
func nativeFill(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async throws -> Data {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		data.append(chunk)
		guard data.count <= 65_536 else { throw ActionError("The fill request exceeds 64 KiB.") }
	}
	let request = try JSONDecoder().decode(FillRequest.self, from: data)
	var result = FillResult(snapshot_id: request.snapshot)
	var receipt: Receipt?
	var lease: SnapshotMutationLease?
	var invoked = false
	do {
		let secret = try request.secret()
		guard (handshake.enabledOperations ?? handshake.supportedOperations).contains(.secureTextFill) else {
			throw ActionError("The native runtime does not fill password fields. Update the desktop runtime before acting.")
		}
		result.requires_fresh_observation = true
		guard try await client.ownsSnapshot(snapshotId: request.snapshot) else {
			throw ActionError("This observation no longer belongs to the running desktop. Inspect the window again.")
		}
		let detection = try await client.getDetectionResult(snapshotId: request.snapshot)
		let (context, identity, bounds) = try snapshotWindow(detection)
		receipt = Receipt(
			pid: identity.ownerProcessIdentifier,
			window_id: identity.windowID,
			process_start_identity_decimal: String(identity.ownerProcessStartIdentity)
		)
		guard let observed = detection.elements.findById(request.element) else {
			throw ActionError("The element ID is not in this snapshot. Inspect the window again.")
		}
		guard isSecure(observed) else {
			throw ActionError("This is not a secure text field. Use desktop_type for other text fields.")
		}
		// Clicking to focus the field could also act on the page, so the field must already have keyboard focus.
		guard let focused = context.focusedElement, matches(focused, observed) else {
			throw ActionError(
				"The password field doesn't have keyboard focus in this snapshot. Nothing was typed.",
				hint: "Click the field with desktop_click, inspect the window again, then fill it with the new snapshot."
			)
		}
		lease = try await client.beginSnapshotMutation(snapshotId: request.snapshot)
		invoked = true
		let filled = try await client.secureTextFillWithOutcome(
			.init(
				snapshotId: request.snapshot, expectedWindowIdentity: identity, expectedWindowBounds: bounds,
				expectedFocusedElement: focused, secret: secret
			),
			timeoutSec: fillTimeout
		)
		guard let outcome = filled.outcome,
			let target = filled.targetIdentity?.exactWindow,
			target.identity.hasSameStableReceipt(as: identity), target.bounds == bounds
		else {
			throw ActionError("The fill returned without its expected outcome and exact-window receipt. Inspect before retrying.")
		}
		result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
		try await client.finishSnapshotMutation(lease!, requiresFreshObservation: result.requires_fresh_observation)
		lease = nil
		if filled.payload, outcome.state == .confirmedChange {
			result.outcome = "completed"
		} else {
			result.outcome = outcome.dispatchState.mutationDispatched ? "unknown" : "refused"
			if result.outcome == "unknown" {
				result.error = FillMessage(
					code: "FILL_UNVERIFIED",
					message: "The password was typed, but the field didn't show the expected number of characters.",
					hint: "Inspect the window. Clear the field before filling it again; don't submit the form unverified."
				)
			}
		}
	} catch let failure as DesktopActionFailure {
		let dispatched = failure.outcome.dispatchState.mutationDispatched
		result.outcome = dispatched ? "unknown" : "refused"
		result.requires_fresh_observation = dispatched || failure.outcome.escalation == .refreshTarget
		// The host refuses before typing when the user or the Keychain declined, or the field or focus didn't qualify.
		result.error = FillMessage(
			code: failure.standardErrorCode?.rawValue ?? (dispatched ? "DESKTOP_ACTION_FAILED" : "FILL_REFUSED"),
			message: failure.message, hint: failure.hint
		)
		if let lease { try? await client.finishSnapshotMutation(lease, requiresFreshObservation: dispatched) }
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		result.error = FillMessage(
			code: (error as? PeekabooBridgeErrorEnvelope)?.code.rawValue ?? (error as? ActionError)?.code
				?? "DESKTOP_ACTION_FAILED",
			message: error.localizedDescription,
			hint: invoked ? "Inspect the window before retrying; the password may already have been typed." : (error as? ActionError)?.hint
		)
	}
	return try JSONEncoder().encode(FillReply(data: result, target_receipt: receipt))
}

/// Whether the snapshot's keyboard focus is the observed element, by role and frame.
private func matches(_ focused: FocusedElementIdentity, _ observed: DetectedElement) -> Bool {
	focused.role == observed.attributes["role"]
		&& abs(focused.frame.minX - observed.bounds.minX) <= 1 && abs(focused.frame.minY - observed.bounds.minY) <= 1
		&& abs(focused.frame.width - observed.bounds.width) <= 1 && abs(focused.frame.height - observed.bounds.height) <= 1
}

/// What a refusal from a key press or insertion into a focused password field says to do instead.
let secureFieldRequiresFill = (
	code: "SECURE_FIELD_REQUIRES_FILL",
	hint: "Fill password fields with desktop_fill_password, from a Keychain item or with the user's approval."
)
