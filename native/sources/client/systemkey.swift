import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

private struct SystemKeyInput: Decodable {
	let key: String
	let modifiers: [String]?
}

private struct SystemKeyMessage: Encodable {
	let code: String
	let message: String
	let hint: String?
}

private struct SystemKeyResult: Encodable {
	var outcome = "refused"
	let action = "system-key"
	var native_outcome: DesktopActionOutcome?
	var requires_fresh_observation = false
	var message: String?
	var error: SystemKeyMessage?
}

private struct SystemKeyReply: Encodable {
	let success = true
	let data: SystemKeyResult
}

/// Posts one chord as global keyboard input to whatever is frontmost; nothing reads back its effect.
func nativeSystemKey(_ client: PeekabooBridgeClient, handshake: PeekabooBridgeHandshakeResponse) async throws -> Data {
	var result = SystemKeyResult()
	var invoked = false
	do {
		var data = Data()
		while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
			guard data.count + chunk.count <= 4096 else { throw ActionError("The system key request exceeds 4 KiB.") }
			data.append(chunk)
		}
		let input = try JSONDecoder().decode(SystemKeyInput.self, from: data)
		guard let primary = serviceKey(input.key) else {
			throw ActionError("Choose a named key or the one printable character a key types, such as , or a.")
		}
		let modifiers = input.modifiers ?? []
		guard modifiers.count <= 4, Set(modifiers).count == modifiers.count,
			modifiers.allSatisfy({ keyboardModifiers[$0] != nil })
		else { throw ActionError("Use each of command, control, option, and shift at most once.") }
		// With other modifiers these chords close all windows, hide other apps, or log out.
		if modifiers.contains("command"), let tool = semanticShortcuts[input.key] {
			throw modifiers == ["command"]
				? ActionError(
					"Command-\(input.key.uppercased()) would \(tool.dropFirst("desktop_".count)) whatever is frontmost, so it isn't sent.",
					hint: "Use \(tool) instead; it acts on an exact target and reports whether it took effect."
				)
				: ActionError(
					"Chords with Command and W, Q, H or M close, quit, hide or minimize whatever is frontmost, or log out, so they aren't sent.",
					hint: "Use desktop_close, desktop_quit, desktop_hide or desktop_minimize on an exact target instead."
				)
		}
		guard (handshake.enabledOperations ?? handshake.supportedOperations).contains(.hotkey) else {
			throw ActionError("The native runtime does not allow system-wide keys. Update the desktop runtime before acting.")
		}
		let session = CGSessionCopyCurrentDictionary() as NSDictionary?
		if session?["CGSSessionScreenIsLocked"] as? Bool == true {
			throw ActionError(
				"The macOS GUI session is locked. No key was sent.",
				hint: "Unlock the active user session, then observe the screen before retrying."
			)
		}
		let chord = (modifiers.map { keyboardModifiers[$0]! } + [primary]).joined(separator: ",")
		try Task.checkCancellation()
		invoked = true
		let action = try await client.hotkeyWithOutcome(keys: chord, holdDuration: 0)
		result.native_outcome = action.outcome
		guard let outcome = action.outcome else {
			throw ActionError("The system key returned without its native outcome.")
		}
		result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
		if outcome.state == .refused {
			result.outcome = "refused"
		} else {
			// Delivery to the frontmost receiver is all the host can attest; the shortcut's effect is never read back.
			result.outcome = "unknown"
			result.message = "The keys went to whatever was frontmost; their effect was not read back. Observe with desktop_screen, desktop_apps or desktop_windows before acting again, and do not blindly repeat the shortcut."
		}
	} catch let failure as DesktopActionFailure {
		result.native_outcome = failure.outcome
		let dispatched = failure.outcome.dispatchState.mutationDispatched
		result.outcome = dispatched ? "unknown" : "refused"
		result.requires_fresh_observation = dispatched
		result.error = SystemKeyMessage(code: failure.standardErrorCode?.rawValue ?? "DESKTOP_ACTION_FAILED", message: failure.message, hint: failure.hint)
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		result.requires_fresh_observation = invoked
		result.error = SystemKeyMessage(
			code: (error as? PeekabooBridgeErrorEnvelope)?.code.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: error.localizedDescription,
			hint: invoked
				? "Observe the screen; the keys may already have been delivered. Do not blindly repeat them."
				: (error as? ActionError)?.hint
		)
	}
	return try JSONEncoder().encode(SystemKeyReply(data: result))
}
