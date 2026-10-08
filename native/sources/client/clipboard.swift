import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

private struct ClipboardRequest: Decodable {
	enum Operation: String, Decodable {
		case read = "clipboard-read"
		case write = "clipboard-write"
	}
	enum Format: String, Decodable {
		case text, image, files
	}
	let op: Operation
	let format: Format?
	let text: String?
	let image: Data?
	let paths: [String]?
}

private struct ClipboardReply<T: Encodable>: Encodable {
	let success = true
	let data: T
}

private struct ClipboardWriteResult: Encodable {
	var outcome = "refused"
	var native_outcome: DesktopActionOutcome?
	var clipboard_changed: Bool?
	var source: ClipboardImageContents.Source?
	var file_count: Int?
	var error: ClipboardMessage?
}

private struct ClipboardMessage: Encodable {
	let code: String
	let message: String
	let hint: String?
}

func nativeClipboard(_ client: PeekabooBridgeClient) async throws -> Data {
	var data = Data()
	while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
		data.append(chunk)
		guard data.count <= 14 * 1024 * 1024 else {
			throw DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest,
				message: "The encoded clipboard request exceeds 14 MiB.")
		}
	}
	let request = try JSONDecoder().decode(ClipboardRequest.self, from: data)
	if request.op == .read {
		guard request.text == nil, request.image == nil, request.paths == nil, data.count <= 65_536 else {
			throw DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest,
				message: "Clipboard reads do not accept content and must fit 64 KiB.")
		}
		if request.format == .files {
			let result = try await client.clipboardFilesRead()
			return try JSONEncoder().encode(ClipboardReply(data: result))
		}
		if request.format == .image {
			let result = try await client.clipboardImageRead()
			return try JSONEncoder().encode(ClipboardReply(data: result))
		}
		let result = try await client.clipboardTextRead()
		return try JSONEncoder().encode(ClipboardReply(data: result))
	}
	var result = ClipboardWriteResult()
	var invoked = false
	do {
		if request.format == .files {
			guard request.text == nil, request.image == nil, let paths = request.paths,
				data.count <= 65_536 else {
				throw DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest,
					message: "File writes require paths without other content and must fit 64 KiB.")
			}
			invoked = true
			let written = try await client.clipboardFilesWrite(paths)
			result.outcome = written.outcome
			result.native_outcome = written.native_outcome
			result.clipboard_changed = written.clipboard_changed
			result.file_count = written.file_count
			if let error = written.error {
				result.error = .init(code: error.code, message: error.message, hint: error.hint)
			}
			return try JSONEncoder().encode(ClipboardReply(data: result))
		}
		if request.format == .image {
			guard request.text == nil, request.paths == nil, let image = request.image,
				!image.isEmpty, image.count <= 10 * 1024 * 1024 else {
				throw DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest,
					message: "Image writes require at most 10 MiB of image data and no text.")
			}
			invoked = true
			let written = try await client.clipboardImageWrite(image)
			result.outcome = written.outcome
			result.native_outcome = written.native_outcome
			result.clipboard_changed = written.clipboard_changed
			result.source = written.source
			if let error = written.error {
				result.error = .init(code: error.code, message: error.message, hint: error.hint)
			}
			return try JSONEncoder().encode(ClipboardReply(data: result))
		}
		guard request.format == nil, request.image == nil, request.paths == nil, data.count <= 65_536 else {
			throw DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest,
				message: "Supply plain text, format image with image data, or format files with paths.")
		}
		guard let text = request.text, text.utf16.count <= 8192 else {
			throw DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest,
				message: "Clipboard text must contain at most 8192 UTF-16 code units.")
		}
		invoked = true
		let written = try await client.clipboardTextWrite(text)
		result.outcome = written.outcome
		result.native_outcome = written.native_outcome
		result.clipboard_changed = written.clipboard_changed
		if let error = written.error {
			result.error = .init(code: error.code, message: error.message, hint: error.hint)
		}
	} catch let failure as DesktopActionFailure {
		let changed = failure.outcome.dispatchState.mutationDispatched
		result.outcome = changed ? "unknown" : "refused"
		result.native_outcome = failure.outcome
		result.clipboard_changed = changed
		result.error = .init(code: failure.standardErrorCode?.rawValue ?? "CLIPBOARD_WRITE_FAILED",
			message: failure.message, hint: failure.hint)
	} catch {
		result.outcome = invoked ? "unknown" : "refused"
		result.error = .init(code: "CLIPBOARD_WRITE_FAILED", message: error.localizedDescription,
			hint: invoked ? "Read the clipboard before deciding whether to write again; the write may already have happened." : nil)
	}
	return try JSONEncoder().encode(ClipboardReply(data: result))
}
