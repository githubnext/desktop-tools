import AppKit
import ApplicationServices
import DesktopProtocol
import Foundation

// A paste through the clipboard into the snapshot's focused control, ported from Peekaboo's LiteralInsert,
// ClipboardTemporaryWrite and ClipboardService's temporary writes (MIT). The prior clipboard comes back only once the
// receiver shows the paste, so a Command-V still pending can never paste the restored contents instead.

private func onMain<T>(_ work: () throws -> T) rethrows -> T {
	if Thread.isMainThread { return try work() }
	return try DispatchQueue.main.sync(execute: work)
}

/// Whether a paste no longer needs its reservation, which the reservation's deferred proof reads.
private final class Resolution {
	var value = false
}

/// What a paste puts on the clipboard.
public enum PastePayload: Sendable {
	case text(String)
	/// One image's original bytes, under its own type.
	case image(Data, ClipboardImageSource)
	/// File URLs, and the paths they name.
	case files([String], paths: [String])

	var count: Int {
		switch self {
		case .text: 1
		case .image: 1
		case let .files(urls, _): urls.count
		}
	}
}

/// What a paste did, as LiteralInsertResult reports it: the clipboard's fate is reported apart from the input's.
public struct PasteReport: Sendable {
	public var outcome = "refused"
	public var native: JSON?
	public var clipboardChanged = false
	public var cleanup = "not_needed"
	public var ownership = "released"
	public var consumption = "unverified"
	public var attachmentEvidence: String?
	public var folder: String?
	public var copy: String?
	public var fresh = false
	public var error: JSON?

	/// The fields an insertion result carries, as the native client copies them.
	public var fields: [(String, JSON)] {
		var fields: [(String, JSON)] = [
			("clipboard_changed", JSON(clipboardChanged)), ("clipboard_cleanup", JSON(cleanup)),
			("clipboard_ownership", JSON(ownership)), ("consumption", JSON(consumption)),
		]
		if let attachmentEvidence { fields.append(("attachment_evidence", JSON(attachmentEvidence))) }
		if let folder { fields.append(("folder", JSON(folder))) }
		if let copy { fields.append(("copy", JSON(copy))) }
		if let error { fields.append(("error", error)) }
		return fields
	}
}

/// A guarded attachment paste into a receiver whose text can't show the attachment.
public let attachmentPasteRefusal = (
	message: "This receiver can't show a pasted attachment through Accessibility, so the paste could never be confirmed and the prior clipboard could never be restored. Nothing was pasted.",
	hint: "Pass clipboard replace to paste and leave the clipboard replaced, or write it with desktop_clipboard_write and press Command-V with desktop_key."
)

/// Files whose names a Finder folder already holds: Finder would ask to replace them or keep both.
public let finderPasteRefusal = (
	suffix: "Finder would ask whether to replace it or keep both, so nothing was pasted.",
	hint: "Rename or remove the existing item, or paste into another folder. desktop_insert never answers Finder's replace dialog."
)

private func pasteRefusal(_ message: String) -> Refusal { Refusal("DESKTOP_ACTION_FAILED", message) }

private func errorJSON(_ code: String, _ message: String, hint: String? = nil, cause: String? = nil) -> JSON {
	.object(["code": JSON(code), "message": JSON(message), "hint": hint.map(JSON.string), "cause": cause.map(JSON.string)])
}

/// A clipboard write that keeps the prior items, and restores them only while the clipboard still holds its write.
private enum TemporaryWriteError: Error, CustomStringConvertible {
	case snapshotChanged, snapshotUnavailable, ownershipChanged

	var description: String {
		switch self {
		case .snapshotChanged: "The clipboard changed while preparing a temporary write; no temporary payload was written."
		case .snapshotUnavailable: "The complete prior clipboard could not be read; no temporary payload was written."
		case .ownershipChanged: "The clipboard changed outside this transaction; automatic writes stopped to preserve newer contents."
		}
	}
}

private final class TemporaryWrite: @unchecked Sendable {
	/// nil for a replacing write, which keeps no copy of the prior clipboard.
	let prior: [[(String, Data)]]?
	let original: Int
	private(set) var claim: Int?
	var didMutate: Bool { claim != nil }

	init(replacing: Bool) throws {
		let read: () throws -> (Int, [[(String, Data)]]?) = {
			let pasteboard = NSPasteboard.general
			let original = pasteboard.changeCount
			guard !replacing else { return (original, nil) }
			guard let items = pasteboard.pasteboardItems else { throw TemporaryWriteError.snapshotUnavailable }
			guard !items.isEmpty else {
				guard pasteboard.types?.isEmpty == true else { throw TemporaryWriteError.snapshotUnavailable }
				return (original, [])
			}
			guard items.count <= 128 else { throw TemporaryWriteError.snapshotUnavailable }
			var bytes = 0, representations = 0
			let prior = try items.map { item in
				guard !item.types.isEmpty else { throw TemporaryWriteError.snapshotUnavailable }
				representations += item.types.count
				guard representations <= 512 else { throw TemporaryWriteError.snapshotUnavailable }
				return try item.types.map { type in
					guard !type.rawValue.localizedCaseInsensitiveContains("promise"), let data = item.data(forType: type),
					      data.count <= 32 * 1024 * 1024 - bytes
					else { throw TemporaryWriteError.snapshotUnavailable }
					bytes += data.count
					return (type.rawValue, data)
				}
			}
			guard pasteboard.changeCount == original else { throw TemporaryWriteError.snapshotChanged }
			return (original, prior)
		}
		(original, prior) = try onMain(read)
	}

	var changeCount: Int { onMain { NSPasteboard.general.changeCount } }

	/// Writes the payload, claiming the clipboard at the change count its declaration returns.
	func write(_ payload: PastePayload) throws {
		try onMain {
			let pasteboard = NSPasteboard.general
			guard pasteboard.changeCount == original else { throw TemporaryWriteError.snapshotChanged }
			let owned = { (count: Int) in if pasteboard.changeCount != count { throw TemporaryWriteError.ownershipChanged } }
			switch payload {
			case let .files(urls, _):
				let items = urls.map { url in
					let item = NSPasteboardItem()
					item.setData(Data(url.utf8), forType: .fileURL)
					return item
				}
				let declared = pasteboard.clearContents()
				claim = declared
				guard pasteboard.writeObjects(items) else {
					try owned(declared)
					throw ToolError("Unable to publish all file reference items")
				}
				try owned(declared)
			case let .text(text):
				let data = Data(text.utf8)
				let declared = pasteboard.declareTypes([.init("public.plain-text"), .string], owner: nil)
				claim = declared
				for type in ["public.plain-text", NSPasteboard.PasteboardType.string.rawValue] {
					try owned(declared)
					guard pasteboard.setData(data, forType: .init(type)) else { throw ToolError("Unable to set type \(type)") }
				}
				try owned(declared)
				guard pasteboard.setString(text, forType: .string) else { throw ToolError("Unable to set the plain-text companion") }
				try owned(declared)
			case let .image(data, source):
				let declared = pasteboard.declareTypes([.init(source.uti)], owner: nil)
				claim = declared
				guard pasteboard.setData(data, forType: .init(source.uti)) else {
					try owned(declared)
					throw ToolError("Unable to set type \(source.uti)")
				}
				try owned(declared)
			}
		}
	}

	/// restored, preserved_newer_contents or not_needed; restores only while the clipboard still holds this write.
	func cleanup() throws -> String {
		try onMain {
			guard let claim else { return "not_needed" }
			let pasteboard = NSPasteboard.general
			guard pasteboard.changeCount == claim, let prior else { return "preserved_newer_contents" }
			let items = try prior.map { representations in
				let item = NSPasteboardItem()
				for (type, data) in representations where !item.setData(data, forType: .init(type)) {
					throw ToolError("Unable to prepare a prior clipboard representation")
				}
				return item
			}
			let cleared = pasteboard.clearContents()
			guard pasteboard.changeCount == cleared else { return "preserved_newer_contents" }
			if !items.isEmpty, !pasteboard.writeObjects(items) {
				guard pasteboard.changeCount == cleared else { return "preserved_newer_contents" }
				throw ToolError("Unable to restore the prior clipboard items")
			}
			return "restored"
		}
	}
}

/// The receiver's text and selection, read twice around the selection so a change between reads is never mixed.
private struct ReceiverState {
	let text: String
	let location: Int
	let length: Int
	/// Characters marked as attachments in the requested range; nil when the attributed text is unreadable.
	var attachmentsMarked: Int?

	func matches(text: String, location: Int, length: Int) -> Bool {
		self.text.utf16.elementsEqual(text.utf16) && self.location == location && self.length == length
	}

	static func read(_ element: AXUIElement, target: KeyboardTarget, attachmentRange: NSRange? = nil) -> ReceiverState? {
		let window = target.window
		AXUIElementSetMessagingTimeout(element, 0.2)
		func focusedValue() -> String? {
			let app = AXUIElementCreateApplication(window.pid)
			AXUIElementSetMessagingTimeout(app, 0.2)
			guard Mac.generation(window.pid) == window.generation,
			      let focused = AX.element(AX.value(app, kAXFocusedUIElementAttribute)), CFEqual(focused, element),
			      let frame = AX.frame(element), window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
			else { return nil }
			return AX.string(element, kAXValueAttribute)
		}
		guard let text = focusedValue(), text.utf16.count <= 65_536,
		      let raw = AX.value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID()
		else { return nil }
		var range = CFRange()
		let count = text.utf16.count
		guard AXValueGetType(raw as! AXValue) == .cfRange, AXValueGetValue(raw as! AXValue, .cfRange, &range),
		      range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location,
		      let again = focusedValue(), again.utf16.elementsEqual(text.utf16)
		else { return nil }
		var state = ReceiverState(text: text, location: range.location, length: range.length)
		if let attachmentRange, attachmentRange.upperBound <= count {
			state.attachmentsMarked = attachmentsMarked(element, in: attachmentRange)
		}
		return state
	}

	/// Accessibility marks each attachment character with AXAttachment.
	private static func attachmentsMarked(_ element: AXUIElement, in range: NSRange) -> Int? {
		var span = CFRange(location: range.location, length: range.length)
		guard let parameter = AXValueCreate(.cfRange, &span) else { return nil }
		var value: CFTypeRef?
		guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
		      let string = value as? NSAttributedString, string.length == range.length
		else { return nil }
		var marked = 0
		string.enumerateAttribute(NSAttributedString.Key("AXAttachment"), in: NSRange(location: 0, length: string.length)) { attachment, run, _ in
			if attachment != nil { marked += run.length }
		}
		return marked
	}
}

/// What a paste should leave in the receiver: its text with the selection replaced and the caret after it.
private struct PasteExpectation {
	let baseline: ReceiverState
	let text: String
	let location: Int
	/// Attachment characters inserted at the selection; zero for text.
	let attachments: Int

	var meaningful: Bool { !baseline.matches(text: text, location: location, length: 0) }
	var attachmentRange: NSRange? { attachments > 0 ? NSRange(location: location - attachments, length: attachments) : nil }

	/// nil until the receiver shows the paste.
	func evidence(_ observed: ReceiverState?) -> String? {
		guard let observed, observed.matches(text: text, location: location, length: 0) else { return nil }
		guard attachments > 0 else { return "text" }
		switch observed.attachmentsMarked {
		case nil, 0?: return "replacement_characters"
		case attachments?: return "attachment_attribute"
		default: return nil
		}
	}
}

/// Files pasted into a Finder folder are seen once every name is present there.
private struct FolderExpectation {
	let folder: URL
	let names: [String]

	func present() -> Bool { names.allSatisfy { Self.exists(folder.appendingPathComponent($0)) } }
	func existing() -> String? { names.first { Self.exists(folder.appendingPathComponent($0)) } }

	/// lstat, so a dangling symbolic link counts as present, as it does for Finder.
	private static func exists(_ url: URL) -> Bool {
		var info = stat()
		return lstat(url.path, &info) == 0
	}

	func validate() throws {
		guard let name = existing() else { return }
		var refusal = Refusal("PASTE_NAME_EXISTS", "\(name) already exists in \(folder.path). \(finderPasteRefusal.suffix)", hint: finderPasteRefusal.hint, fromHost: false)
		refusal.reason = "operation_unsupported"
		throw refusal
	}
}

extension Mac {
	/// Pastes text into the snapshot's focused control and restores the prior clipboard once the edit shows.
	public static func pasteText(_ text: String, target: KeyboardTarget) throws -> PasteReport {
		guard !text.isEmpty, text.utf16.count <= 8192, target.focusedRole != nil else {
			throw pasteRefusal("Literal insertion requires 1–8192 UTF-16 units and an exact focused receiver.")
		}
		return try ClipboardGate.exclusive { transaction in
			let focused = try requireKeyboardFocus(target)
			if secureFocus(focused) { throw secureFocusRefusal }
			guard let baseline = ReceiverState.read(focused, target: target),
			      let range = Range(NSRange(location: baseline.location, length: baseline.length), in: baseline.text)
			else { throw pasteRefusal("The exact receiver's complete text and selection cannot be read safely.") }
			let expected = baseline.text.replacingCharacters(in: range, with: text)
			guard expected.utf16.count <= 65_536 else { throw pasteRefusal("The intended edit exceeds the complete text verification limit.") }
			let write: TemporaryWrite
			do { write = try TemporaryWrite(replacing: false) } catch let error as TemporaryWriteError {
				throw pasteRefusal("Literal insertion could not establish its read-only preflight: \(error.description)")
			}
			return try paste(
				.text(text), write: write, expectation: PasteExpectation(baseline: baseline, text: expected, location: baseline.location + text.utf16.count, attachments: 0),
				folder: nil, replace: false, focused: focused, target: target, transaction: transaction
			)
		}
	}

	/// Pastes an image or file references into the focused control, or files into a Finder folder. Only a native
	/// text area shows a pasted attachment, and only a Finder folder shows pasted files, so any other receiver takes
	/// a paste only when the caller lets the clipboard stay replaced.
	public static func pasteAttachment(_ payload: PastePayload, replace: Bool, target: KeyboardTarget) throws -> PasteReport {
		guard target.focusedRole != nil else { throw pasteRefusal("Attachment insertion requires an exact focused receiver.") }
		return try ClipboardGate.exclusive { transaction in
			let focused = try requireKeyboardFocus(target)
			if secureFocus(focused) { throw secureFocusRefusal }
			var folder: FolderExpectation?
			var expectation: PasteExpectation?
			if case let .files(_, paths) = payload, NSRunningApplication(processIdentifier: target.window.pid)?.bundleIdentifier == "com.apple.finder" {
				folder = try finderFolder(focused, role: target.focusedRole, paths: paths)
			} else if target.focusedRole == "AXTextArea", !isWebField(focused), let baseline = ReceiverState.read(focused, target: target),
			          let range = Range(NSRange(location: baseline.location, length: baseline.length), in: baseline.text)
			{
				let text = baseline.text.replacingCharacters(in: range, with: String(repeating: "\u{FFFC}", count: payload.count))
				guard text.utf16.count <= 65_536 else { throw pasteRefusal("The intended edit exceeds the complete text verification limit.") }
				expectation = PasteExpectation(baseline: baseline, text: text, location: baseline.location + payload.count, attachments: payload.count)
			}
			guard expectation != nil || folder != nil || replace else {
				var refusal = Refusal("PASTE_UNVERIFIABLE_RECEIVER", attachmentPasteRefusal.message, hint: attachmentPasteRefusal.hint, fromHost: false)
				refusal.reason = "operation_unsupported"
				throw refusal
			}
			let write: TemporaryWrite
			do { write = try TemporaryWrite(replacing: replace) } catch let error as TemporaryWriteError {
				throw pasteRefusal("Attachment insertion could not establish its read-only preflight: \(error.description)")
			}
			return try paste(payload, write: write, expectation: expectation, folder: folder, replace: replace, focused: focused, target: target, transaction: transaction)
		}
	}

	/// One temporary paste into the exact receiver, then the wait for its evidence and the clipboard's cleanup.
	private static func paste(
		_ payload: PastePayload, write: TemporaryWrite, expectation: PasteExpectation?, folder: FolderExpectation?, replace: Bool,
		focused: AXUIElement, target: KeyboardTarget, transaction: ClipboardTransaction
	) throws -> PasteReport {
		guard replace || clipboardReadAdmitted() else {
			var refusal = Refusal(
				"DESKTOP_ACTION_FAILED", "Programmatic clipboard reads require silently allowed access.",
				hint: "No clipboard contents were read. Check clipboard status and arrange permission outside automation. The manual CLI --allow-prompt option requires intentional human consent."
			)
			refusal.reason = "permission_denied"
			throw refusal
		}
		let meaningful = expectation?.meaningful == true || folder != nil
		var report = PasteReport()
		report.folder = folder?.folder.path
		var possibleInput = false
		// A guarded paste stays reserved from Command-V until its edit is seen, so no later clipboard write or paste
		// replaces what a pending Command-V would paste.
		var reserved = false
		var token: UUID?
		let resolved = Resolution()
		func validateBaseline() throws {
			guard let current = try? requireKeyboardFocus(target), CFEqual(current, focused) else {
				throw pasteRefusal("The exact text receiver or its selection changed before insertion.")
			}
			guard let baseline = expectation?.baseline else { return }
			guard let state = ReceiverState.read(focused, target: target), state.matches(text: baseline.text, location: baseline.location, length: baseline.length) else {
				throw pasteRefusal("The exact text receiver or its selection changed before insertion.")
			}
		}
		do {
			try validateBaseline()
			try folder?.validate()
			try write.write(payload)
			guard let claim = write.claim, write.changeCount == claim, Mac.generation(target.window.pid) == target.window.generation else {
				throw pasteRefusal("Clipboard ownership or the original receiving process changed before paste delivery.")
			}
			try validateBaseline()
			try folder?.validate()
			// An app that isn't active drops a background paste until its window is key.
			if !Mac.isActive(target.window) {
				_ = try prepareBackgroundWindow(target.window)
				try validateBaseline()
				try folder?.validate()
			}
			if !replace, let claim = write.claim {
				token = try transaction.reservePaste(pid: target.window.pid, generation: target.window.generation, windowID: target.window.windowID) {
					if resolved.value { return true }
					if let folder { return write.changeCount == claim && folder.present() }
					guard meaningful, let expectation, write.changeCount == claim else { return false }
					let observed = ReceiverState.read(focused, target: target, attachmentRange: expectation.attachmentRange)
					return expectation.evidence(observed) != nil && write.changeCount == claim
				}
			}
			possibleInput = true
			reserved = !replace
			let delivery = try press(chord("v", modifiers: ["command"]), target: target)
			report.native = delivery.json
			possibleInput = delivery.state != .confirmedNoChange
			report.outcome = "unknown"
		} catch let refusal as Refusal {
			// A name already in the folder is refused as the client words it, before any clipboard change.
			if !refusal.fromHost, !write.didMutate { throw refusal }
			report.native = refusal.outcome
			possibleInput = false
			reserved = false
			report.outcome = "refused"
			report.error = errorJSON("LITERAL_INSERT_FAILED", refusal.message, hint: refusal.hint, cause: refusal.cause)
		} catch let stopped as PreparationStopped {
			// Nothing was pasted, but the app may have seen the activation or the title-bar click.
			report.outcome = "unknown"
			report.error = errorJSON("LITERAL_INSERT_FAILED", "Background keyboard preparation did not finish, so no keys or paste were sent. Its window activation or title-bar click may have reached the app; observe before another input.",
			                         hint: "Observe the target again before retrying.", cause: stopped.cause)
		} catch {
			report.outcome = possibleInput ? "unknown" : "refused"
			report.error = errorJSON("LITERAL_INSERT_FAILED", (error as? ToolError)?.message ?? String(describing: error))
		}
		report.clipboardChanged = write.didMutate
		report.fresh = possibleInput
		let dispatchedState = { ["dispatched_unverified", "confirmed_change"].contains(report.native?["state"]?.string ?? "") }
		if possibleInput, let claim = write.claim, let folder {
			// Finder creates each name as its copy begins; a large copy may still be running when all are present.
			let deadline = ContinuousClock.now + .seconds(5)
			while ContinuousClock.now < deadline, write.changeCount == claim {
				if folder.present() {
					report.consumption = "observed"
					report.copy = "started"
					if dispatchedState() { report.outcome = "completed" }
					break
				}
				Thread.sleep(forTimeInterval: 0.05)
			}
		}
		if possibleInput, meaningful, let claim = write.claim, let expectation {
			let deadline = ContinuousClock.now + .seconds(2)
			while ContinuousClock.now < deadline, write.changeCount == claim, Mac.generation(target.window.pid) == target.window.generation {
				let observed = ReceiverState.read(focused, target: target, attachmentRange: expectation.attachmentRange)
				if let evidence = expectation.evidence(observed) {
					report.consumption = "observed"
					if expectation.attachments > 0 { report.attachmentEvidence = evidence }
					if dispatchedState() { report.outcome = "completed" }
					break
				}
				Thread.sleep(forTimeInterval: 0.02)
			}
		}
		if replace {
			// The caller chose to leave the paste on the clipboard; the prior contents were never kept.
			if report.clipboardChanged { report.cleanup = "left_replaced" }
			if possibleInput, report.consumption != "observed", report.error == nil {
				report.error = errorJSON(
					"INSERTION_UNVERIFIED",
					folder != nil
						? "Command-V was sent, but the files did not appear in the folder. The clipboard was left replaced."
						: expectation == nil
						? "Command-V was sent, but this receiver can't show the attachment through Accessibility. The clipboard was left replaced."
						: "The pasted attachment was not observed in the receiver's text. The clipboard was left replaced.",
					hint: "Inspect the receiver, or capture it with desktop_screen, before another input or clipboard write: a Command-V still pending pastes whatever the clipboard then holds."
				)
			}
		} else if !reserved || report.consumption == "observed" {
			resolved.value = true
			if let token {
				do { try transaction.releasePaste(token) } catch {
					report.error = errorJSON(
						"CLIPBOARD_OWNERSHIP_RELEASE_FAILED",
						folder != nil ? "The files appeared, but shared clipboard ownership could not be released." : report.consumption == "observed" ? "The edit was observed, but shared clipboard ownership could not be released." : "Shared clipboard ownership could not be released."
					)
				}
			}
			do { report.cleanup = try write.cleanup() } catch {
				report.cleanup = "failed"
				if report.error == nil {
					report.error = errorJSON("CLIPBOARD_CLEANUP_FAILED", "The prior clipboard could not be restored; input delivery is reported separately.")
				}
			}
			reserved = false
		} else {
			// The prior clipboard stays unrestored: a delayed Command-V would paste it instead.
			report.cleanup = write.claim.map { write.changeCount == $0 } == true ? "retained_unverified" : "preserved_newer_contents"
			if report.error == nil {
				report.error = errorJSON(
					"INSERTION_UNVERIFIED", "Cmd+V may still be pending. The previous clipboard was not restored.",
					hint: "Inspect the exact receiver before another input; do not repeat the insertion blindly."
				)
			}
		}
		report.ownership = transaction.hasUnresolvedPaste ? "reserved" : "released"
		guard report.clipboardChanged else {
			throw pasteRefusal(report.error?["message"]?.string ?? "Literal insertion was refused before clipboard mutation.")
		}
		return report
	}

	/// The folder a Finder window shows, checked before any input: Command-V would copy into it. A field being
	/// edited, such as a name or the search field, would take the paste as text instead.
	private static func finderFolder(_ focused: AXUIElement, role: String?, paths: [String]) throws -> FolderExpectation {
		let editing: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
		guard let role, !editing.contains(role) else {
			throw pasteRefusal("Finder's keyboard focus is a text field, which would take the paste as text. Click the folder's file list, inspect, and try again.")
		}
		var location: String?
		if let window = AX.element(AX.value(focused, kAXWindowAttribute)) {
			AXUIElementSetMessagingTimeout(window, 0.2)
			for attribute in [kAXDocumentAttribute as String, "AXURL"] {
				let value = AX.value(window, attribute)
				if let url = value as? URL { location = url.absoluteString; break }
				if let text = value as? String { location = text; break }
			}
			// On macOS 27 a Finder window's AXDocument is empty; its path bar's last item still names the folder.
			if location == nil { location = pathBarFolder(window)?.absoluteString }
		}
		guard let location, let url = URL(string: location), url.isFileURL else {
			throw pasteRefusal("This Finder window doesn't report its folder, so the pasted files couldn't be found afterwards. Nothing was pasted. Turn on View > Show Path Bar in Finder, which shows the folder, and try again.")
		}
		let folder = url.standardizedFileURL
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw pasteRefusal("The Finder window's folder \(folder.path) is not a folder on disk. Nothing was pasted.")
		}
		let names = paths.map { ($0 as NSString).lastPathComponent }
		guard Set(names.map { $0.lowercased() }).count == names.count else {
			throw pasteRefusal("Two of the files share a name, so Finder would ask whether to replace one. Nothing was pasted.")
		}
		let expectation = FolderExpectation(folder: folder, names: names)
		try expectation.validate()
		return expectation
	}

	/// The folder in a Finder window's path bar: a list whose items are file URLs, ending at the window's folder.
	private static func pathBarFolder(_ window: AXUIElement) -> URL? {
		func children(_ element: AXUIElement) -> [AXUIElement] {
			AXUIElementSetMessagingTimeout(element, 0.2)
			return AX.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
		}
		func fileURL(_ element: AXUIElement) -> URL? {
			guard let url = AX.value(element, "AXURL") as? URL, url.isFileURL else { return nil }
			return (url as NSURL).filePathURL
		}
		var level = [window]
		var visited = 0
		for _ in 0..<4 {
			var next: [AXUIElement] = []
			for element in level {
				for child in children(element) {
					visited += 1
					if visited > 200 { return nil }
					if AX.string(child, kAXRoleAttribute) == kAXListRole, let title = AX.string(window, kAXTitleAttribute), !title.isEmpty {
						let items = children(child)
						if items.last.flatMap(fileURL) != nil {
							return items.last(where: { AX.string($0, kAXValueAttribute) == title }).flatMap(fileURL)
						}
					}
					next.append(child)
				}
			}
			level = next
		}
		return nil
	}
}
