import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

private struct ActionRequest: Decodable {
	enum Operation: String, Decodable {
		case click, type, key, insert, select, scroll, drag
	}

	let op: Operation
	let snapshot: String
	let element: String?
	let text: String?
	let key: String?
	let modifiers: [String]?
	let prefix: String?
	let suffix: String?
	let selection: String?
	let point: PointerPoint?
	let kind: String?
	let direction: String?
	let amount: Int?
	let from: PointerPoint?
	let to: PointerPoint?
	let button: String?
	let duration_ms: Int?

	func validate() throws {
		guard !snapshot.isEmpty, snapshot.utf16.count <= 256 else {
			throw ActionError("Use a snapshot ID returned by desktop_inspect.")
		}
		if op != .key, modifiers != nil {
			throw ActionError("Only key presses accept modifiers.")
		}
		if op != .select, prefix != nil || suffix != nil || selection != nil {
			throw ActionError("Only text selection accepts prefix, suffix, or selection.")
		}
		if op != .click, kind != nil {
			throw ActionError("Only clicks accept a click kind.")
		}
		if op != .scroll, direction != nil || amount != nil {
			throw ActionError("Only scrolling accepts direction or amount.")
		}
		if op != .drag, from != nil || to != nil || button != nil || duration_ms != nil {
			throw ActionError("Only dragging accepts endpoints, button, or duration.")
		}
		if op != .click, op != .scroll, point != nil {
			throw ActionError("Only clicks or scrolling accept a target point.")
		}
		switch op {
		case .click, .scroll:
			guard (element == nil) != (point == nil), text == nil, key == nil else {
				throw ActionError("Choose exactly one observed element ID or normalized screenshot point.")
			}
			if let element, element.isEmpty || element.utf16.count > 256 {
				throw ActionError("Choose a literal element ID from the inspected snapshot.")
			}
			try point?.validate()
			if op == .click {
				guard kind == nil || pointerClicks.contains(kind!) else {
					throw ActionError("Choose single, double, right, middle, or triple click.")
				}
			} else {
				guard let direction, ScrollDirection(rawValue: direction) != nil,
					let amount, (1...20).contains(amount)
				else { throw ActionError("Choose up, down, left, or right and 1 to 20 native scroll units.") }
			}
		case .drag:
			guard element == nil, text == nil, key == nil, let from, let to, from != to else {
				throw ActionError("Choose distinct normalized screenshot points for the drag endpoints.")
			}
			try from.validate()
			try to.validate()
			guard button == nil || ExactWindowHeldPointerButton(rawValue: button!) != nil,
				ExactWindowDragRequest.durationMillisecondsRange.contains(duration_ms ?? 500)
			else { throw ActionError("Choose a left or right drag lasting 1 to 10000 milliseconds.") }
		case .type, .select:
			guard let element, !element.isEmpty, element.utf16.count <= 256, key == nil else {
				throw ActionError("Choose a literal element ID from the inspected snapshot.")
			}
			if op == .type {
				guard let text, text.utf16.count <= 8192 else {
					throw ActionError("Replacement text must contain at most 8,192 UTF-16 code units.")
				}
			} else if op == .select {
				guard let text, !text.isEmpty, text.utf16.count <= 4096,
					(prefix?.utf16.count ?? 0) <= 2048, (suffix?.utf16.count ?? 0) <= 2048
				else {
					throw ActionError("Select nonempty text of at most 4,096 UTF-16 code units, with prefix and suffix of at most 2,048 each.")
				}
				if let selection, TextSelectionType(rawValue: selection) == nil {
					throw ActionError("Choose text, cursor_before, or cursor_after selection.")
				}
			}
		case .insert:
			guard element == nil, key == nil, let text, !text.isEmpty, text.utf16.count <= 8192 else {
				throw ActionError("Insert nonempty text of at most 8,192 UTF-16 code units into the observed focused control.")
			}
		case .key:
			guard element == nil, text == nil, let key, keyboardKeys.contains(key) else {
				throw ActionError("Choose a supported navigation key, letter, digit, or f1 through f12.")
			}
			let modifiers = modifiers ?? []
			guard modifiers.count <= 4, Set(modifiers).count == modifiers.count,
				modifiers.allSatisfy({ keyboardModifiers.contains($0) })
			else {
				throw ActionError("Use each of command, control, option, and shift at most once.")
			}
		}
	}
}

private struct PointerPoint: Decodable, Equatable {
	let x: Double
	let y: Double

	func validate() throws {
		guard x.isFinite, y.isFinite, (0..<1).contains(x), (0..<1).contains(y) else {
			throw ActionError("Screenshot point coordinates must be at least 0 and less than 1.")
		}
	}

	func mapped(in authority: SnapshotTargetReceipt.CoordinateAuthority) throws -> CGPoint {
		let point = try CaptureCoordinateMapper.globalPoint(
			for: CGPoint(x: x, y: y), in: .normalized, context: authority.context
		)
		guard authority.target.bounds.contains(point) else {
			throw ActionError("The screenshot point is outside its exact captured window.")
		}
		return point
	}
}

private let pointerClicks: Set<String> = ["single", "double", "right", "middle", "triple"]
private let keyboardModifiers: Set<String> = ["command", "control", "option", "shift"]
private let keyboardKeys: Set<String> = {
	var keys: Set<String> = [
		"enter", "tab", "escape", "backspace", "delete", "up", "down", "left", "right",
		"space", "home", "end", "pageup", "pagedown",
	]
	keys.formUnion("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
	keys.formUnion((1...12).map { "f\($0)" })
	return keys
}()

private struct ActionError: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

private struct ActionEvidence {
	let outcome: DesktopActionOutcome?
	let target: DesktopTargetIdentity?
	let selected: [DesktopSelectedLeafEvidence]?

	init<T: Sendable>(_ result: UIAutomationActionResult<T>) {
		outcome = result.outcome
		target = result.targetIdentity
		selected = result.selectedLeafEvidence
	}
}

private struct ActionResult: Encodable {
	var outcome: String
	let action: String
	let snapshot_id: String
	var native_outcome: DesktopActionOutcome?
	var selected_leaf_evidence: [DesktopSelectedLeafEvidence]?
	var selection: TextSelectionResult?
	var clipboard_changed: Bool?
	var clipboard_cleanup: String?
	var clipboard_ownership: String?
	var consumption: String?
	var requires_fresh_observation = false
	var error: ActionMessage?
}

private struct ActionMessage: Encodable {
	let code: String
	let message: String
	var hint: String?
	var cause: String?
}

private struct ActionReply: Encodable {
	let success = true
	let data: ActionResult
	let target_receipt: Receipt?
}

func nativeAction(_ client: PeekabooBridgeClient) async throws -> Data {
	let request = try readAction()
	var result = ActionResult(outcome: "refused", action: request.op.rawValue, snapshot_id: request.snapshot)
	var receipt: Receipt?
	var lease: SnapshotMutationLease?
	var invoked = false
	do {
		try request.validate()
		let chord = try request.key.map { key in
			// This contract keeps delete as forward delete; Peekaboo's unqualified delete means backspace.
			let primary = key == "delete" ? "forwarddelete" : key
			return try KeyboardChord(parsing: ((request.modifiers ?? []) + [primary]).joined(separator: "+"))
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
		if let element = request.element {
			// Native set-value accepts text queries too; this client accepts only a literal observed ID.
			guard let observed = detection.elements.findById(element) else {
				throw ActionError("The element ID is not in this snapshot. Inspect the window again.")
			}
			guard observed.knownIsEnabled != false else { throw ActionError("The observed element is disabled.") }
		}
		if request.op == .key || request.op == .insert, context.focusedElement == nil {
			throw ActionError("The snapshot has no exact focused control. Click a control, then inspect the window again.")
		}
		if request.op == .insert {
			// The GUI owns the snapshot lease and clipboard transaction through consumption and cleanup.
			invoked = true
			let insertion = try await client.literalInsert(snapshot: request.snapshot, text: request.text!)
			result.outcome = insertion.outcome
			result.native_outcome = insertion.native_outcome
			result.clipboard_changed = insertion.clipboard_changed
			result.clipboard_cleanup = insertion.clipboard_cleanup
			result.clipboard_ownership = insertion.clipboard_ownership
			result.consumption = insertion.consumption
			result.requires_fresh_observation = insertion.requires_fresh_observation
			if let error = insertion.error {
				result.error = ActionMessage(code: error.code, message: error.message, hint: error.hint, cause: error.cause)
			}
			guard let target = insertion.target_receipt,
				target.pid == identity.ownerProcessIdentifier, target.window_id == identity.windowID,
				target.process_start_identity_decimal == String(identity.ownerProcessStartIdentity)
			else {
				throw ActionError("Literal insertion returned without its expected exact-window receipt. Inspect before retrying.")
			}
			return try JSONEncoder().encode(ActionReply(data: result, target_receipt: receipt))
		}
		let window = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
		var scrollWindow: UIAutomationTarget.ExactWindow?
		if request.op == .scroll {
			// Request-pinned scroll receipts retain the snapshot's focus evidence as well as its geometry.
			scrollWindow = try .init(identity: identity, bounds: bounds, focusedElement: context.focusedElement)
		}
		var point: CGPoint?
		var drag: ExactWindowDragRequest?
		if request.point != nil || request.op == .drag {
			// Normalized coordinates survive host image resizing; authority stays in the bridge's capture.
			let authority = try coordinateAuthority(request.snapshot, detection, window: window)
			point = try request.point?.mapped(in: authority)
			if request.op == .drag {
				// Drag validates the full capture receipt; coordinate authority intentionally omits focus.
				let dragWindow = try UIAutomationTarget.ExactWindow(
					identity: identity, bounds: bounds, focusedElement: context.focusedElement
				)
				drag = try ExactWindowDragRequest(
					snapshotID: request.snapshot, target: dragWindow,
					from: request.from!.mapped(in: authority), to: request.to!.mapped(in: authority),
					durationMilliseconds: request.duration_ms ?? 500,
					button: request.button.flatMap(ExactWindowHeldPointerButton.init(rawValue:)) ?? .left
				)
				try drag!.validate()
			}
		}
		lease = try await client.beginSnapshotMutation(snapshotId: request.snapshot)
		invoked = true
		let evidence: ActionEvidence
		switch request.op {
		case .click:
			evidence = try await ActionEvidence(client.clickWithOutcome(
				target: point.map(ClickTarget.coordinates) ?? .elementId(request.element!),
				clickType: request.kind.flatMap(ClickType.init(rawValue:)) ?? .single,
				snapshotId: request.snapshot,
				windowEvidence: .init(identity: identity, bounds: bounds),
				allowsAccessibilityValueDelivery: true
			))
		case .scroll:
			evidence = try await ActionEvidence(client.scrollWithOutcome(.init(
				direction: ScrollDirection(rawValue: request.direction!)!, amount: request.amount!,
				target: request.element, point: point, snapshotId: request.snapshot,
				expectedWindow: scrollWindow!, foreground: false
			)))
		case .drag:
			evidence = try await ActionEvidence(client.dragExactWindow(drag!))
		case .type:
			evidence = try await ActionEvidence(client.setValueWithOutcome(
				target: request.element!, value: .string(request.text!), snapshotId: request.snapshot
			))
		case .key:
			// Text-action emulation rejects WKWebView's focused receiver; deliver the exact-window key instead.
			evidence = try await ActionEvidence(client.hotkeyWithOutcome(
				keys: chord!.serviceKeys,
				holdDuration: 0,
				target: .init(
					windowIdentity: identity,
					windowBounds: bounds,
					focusedElement: context.focusedElement!
				)
			))
		case .insert:
			throw ActionError("Literal insertion must use its GUI-owned transaction.")
		case .select:
			let selected = try await client.selectText(
				target: request.element!,
				request: .init(
					text: request.text!, prefix: request.prefix, suffix: request.suffix,
					selectionType: request.selection.flatMap(TextSelectionType.init(rawValue:)) ?? .text
				),
				snapshotId: request.snapshot
			)
			evidence = ActionEvidence(selected)
			result.selection = selected.payload.textSelection
		}
		result.native_outcome = evidence.outcome
		result.selected_leaf_evidence = evidence.selected
		guard let outcome = evidence.outcome,
			let target = evidence.target?.exactWindow,
			target.identity.hasSameStableReceipt(as: identity), target.bounds == bounds
		else {
			throw ActionError("The action returned without its expected outcome and exact-window receipt. Inspect before retrying.")
		}
		// Every dispatched action consumes this snapshot, including confirmed changes and partial cleanup.
		result.requires_fresh_observation = outcome.dispatchState.mutationDispatched
		try await client.finishSnapshotMutation(lease!, requiresFreshObservation: result.requires_fresh_observation)
		lease = nil
		switch outcome.state {
		case .refused:
			result.outcome = "refused"
		case .indeterminate, .partial:
			result.outcome = "unknown"
		default:
			result.outcome = outcome.evidence == .operationStillRunning ? "unknown" : "completed"
		}
	} catch let failure as DesktopActionFailure {
		result.outcome = failure.outcome.dispatchState.mutationDispatched ? "unknown" : "refused"
		result.native_outcome = failure.outcome
		result.selected_leaf_evidence = failure.selectedLeafEvidence
		let dispatched = failure.outcome.dispatchState.mutationDispatched
		result.requires_fresh_observation = dispatched || failure.outcome.escalation == .refreshTarget
		result.error = ActionMessage(
			code: failure.standardErrorCode?.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: failure.message, hint: failure.hint
		)
		if let lease {
			do {
				try await client.finishSnapshotMutation(lease, requiresFreshObservation: dispatched)
			} catch {
				result.requires_fresh_observation = true
			}
		}
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		if invoked { result.requires_fresh_observation = true }
		let envelope = error as? PeekabooBridgeErrorEnvelope
		result.error = ActionMessage(
			code: envelope?.code.rawValue ?? "DESKTOP_ACTION_FAILED",
			message: error.localizedDescription,
			hint: invoked ? "Inspect the target before retrying; the action may already have happened." : nil
		)
		// Unknown completion leaves the host's pending lease in place, including client death or response loss.
	}
	return try JSONEncoder().encode(ActionReply(data: result, target_receipt: receipt))
}

func snapshotWindow(
	_ detection: ElementDetectionResult
) throws -> (WindowContext, WindowMutationIdentity, CGRect) {
	guard let context = detection.metadata.windowContext,
		let identity = context.windowMutationIdentity,
		let bounds = context.windowBounds,
		context.windowID == identity.windowID,
		context.applicationProcessId == identity.ownerProcessIdentifier
	else {
		throw ActionError("This observation has no exact-window action target. Inspect the window again.")
	}
	return (context, identity, bounds)
}

func coordinateAuthority(
	_ snapshot: String, _ detection: ElementDetectionResult, window: UIAutomationTarget.ExactWindow
) throws -> SnapshotTargetReceipt.CoordinateAuthority {
	let authority = try SnapshotTargetReceiptPlanner.assemble(
		snapshotID: snapshot, detectionResult: detection
	).receipt.requireCoordinateAuthority()
	guard authority.target == window, let captured = authority.context.logicalBounds,
		window.bounds.contains(captured), !detection.screenshotPath.isEmpty
	else { throw ActionError("This observation has no pixel-backed coordinate authority for its exact window.") }
	return authority
}

private func readAction() throws -> ActionRequest {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		data.append(chunk)
		guard data.count <= 65_536 else { throw ActionError("The desktop action request exceeds 64 KiB.") }
	}
	return try JSONDecoder().decode(ActionRequest.self, from: data)
}
