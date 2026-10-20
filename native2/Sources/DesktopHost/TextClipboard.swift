import DesktopCore
import DesktopMac
import DesktopProtocol
import Foundation

// desktop_clipboard_read and desktop_clipboard_write, with Node's argument checks from src/tools.ts and
// src/client.ts, and the save step from src/capture-file.ts's saveClipboardImage.

/// File extensions a clipboard image may be saved with, by its type.
private let clipboardExtensions: [String: [String]] = [
	"public.png": ["png"], "public.jpeg": ["jpg", "jpeg"], "public.tiff": ["tif", "tiff"],
]
private let maximumClipboardImage = 10 * 1024 * 1024

/// Node's message for a failed file system call, as libuv words it.
private func nodeError(_ code: Int32, _ call: String, _ path: String) -> ToolError {
	let names: [Int32: (String, String)] = [
		ENOENT: ("ENOENT", "no such file or directory"), EACCES: ("EACCES", "permission denied"),
		ENOTDIR: ("ENOTDIR", "not a directory"), ELOOP: ("ELOOP", "too many symbolic links encountered"),
		ENAMETOOLONG: ("ENAMETOOLONG", "name too long"), EPERM: ("EPERM", "operation not permitted"),
		EIO: ("EIO", "i/o error"), EMFILE: ("EMFILE", "too many open files"),
	]
	let (name, text) = names[code] ?? ("E\(code)", String(cString: strerror(code)).lowercased())
	return ToolError("\(name): \(text), \(call) '\(path)'")
}

func isAbsoluteClipboardPath(_ path: String) -> Bool {
	path.hasPrefix("/") && path.utf16.count <= 4096 && !path.contains("\0")
}

extension Tools {
	/// Each path must name an existing file, folder or link; links are not followed.
	static func checkFileReferences(_ paths: [String]) throws {
		for path in paths {
			var entry = stat()
			guard lstat(path, &entry) == 0 else { throw nodeError(errno, "lstat", path) }
			let kind = entry.st_mode & S_IFMT
			guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else {
				throw ToolError("Clipboard file references require existing files, directories, or symbolic links.")
			}
		}
	}

	/// A whole image file read without blocking on a pipe, refused if it changed while being read.
	static func clipboardImageFile(_ path: String) throws -> Data {
		let descriptor = open(path, O_RDONLY | O_NONBLOCK)
		guard descriptor >= 0 else { throw nodeError(errno, "open", path) }
		defer { close(descriptor) }
		var before = stat()
		guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0,
		      before.st_size <= maximumClipboardImage
		else { throw ToolError("Clipboard images require a nonempty regular file of at most 10 MiB.") }
		var data = Data(count: Int(before.st_size) + 1)
		var size = 0
		try data.withUnsafeMutableBytes { buffer in
			while size < buffer.count {
				let read = pread(descriptor, buffer.baseAddress! + size, buffer.count - size, off_t(size))
				if read < 0 { throw nodeError(errno, "read", path) }
				if read == 0 { break }
				size += read
			}
		}
		var after = stat()
		guard fstat(descriptor, &after) == 0, size == Int(before.st_size), after.st_size == before.st_size,
		      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
		      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
		else { throw ToolError("The image file changed while being read; choose a stable file before writing.") }
		return data.prefix(size)
	}

	// MARK: desktop_clipboard_read

	static func clipboardRead(_ arguments: JSON) async throws -> ToolResult {
		let format = arguments["format"]
		guard format == nil || format == "text" || format == "image" || format == "files" else {
			throw ToolError("Choose text, image, or files clipboard format.")
		}
		if format == "image", arguments["save_path"] != nil { return try await exportClipboardImage(arguments) }
		if arguments["save_path"] != nil || arguments["overwrite"] != nil {
			throw ToolError("save_path and overwrite apply to format image only.")
		}
		if format == "files" { return ToolResult(text: try await run { try Mac.readClipboardFiles() }.text) }
		if format == "image" {
			let read = try await run { try Mac.readClipboardImage(original: false) }
			return imageResult(read)
		}
		return ToolResult(text: try await run { try Mac.readClipboardText() }.text)
	}

	private static func imageResult(_ read: ClipboardImageRead, saved: JSON? = nil) -> ToolResult {
		guard let source = read.source, let preview = read.preview, let data = read.previewData, let mime = read.previewMimeType else {
			return ToolResult(text: JSON.object([("present", false), ("change_count", JSON(read.changeCount))]).text)
		}
		var fields: [(String, JSON)] = [("present", true), ("change_count", JSON(read.changeCount)), ("source", source.json), ("preview", preview)]
		if let saved { fields.append(("saved", saved)) }
		return ToolResult(text: JSON.object(fields).text, image: (data: data, mimeType: mime))
	}

	/// Saves the clipboard image's original bytes, unchanged, so save_path's extension must name its own type.
	private static func exportClipboardImage(_ arguments: JSON) async throws -> ToolResult {
		// Node passes only the tool's own arguments on, so region never reaches the save check here.
		var own: [(String, JSON)] = []
		for key in ["save_path", "overwrite"] { if let value = arguments[key] { own.append((key, value)) } }
		guard let request = try saveRequest(.object(own), extensions: ["png", "jpg", "jpeg", "tif", "tiff"]) else {
			throw ToolError("save_path must be a normalized absolute path ending in .png, .jpg, .jpeg, .tif or .tiff.")
		}
		let read = try await run { try Mac.readClipboardImage(original: true) }
		guard let source = read.source, let original = read.original else {
			return ToolResult(text: JSON.object([
				("present", false), ("change_count", JSON(read.changeCount)), ("saved", .null),
				("note", "The clipboard holds no image; nothing was written."),
			]).text)
		}
		guard let extensions = clipboardExtensions[source.uti] else {
			throw ToolError("The clipboard image type \(source.uti) can't be saved.")
		}
		guard extensions.contains(String(request.path.split(separator: ".").last ?? "").lowercased()) else {
			throw ToolError("The clipboard holds a \(source.mimeType) image; save it with a .\(extensions.joined(separator: " or .")) path. Nothing was written.")
		}
		// Exclusive unless overwrite was asked for, so a file created since validation is never replaced.
		try original.write(to: URL(fileURLWithPath: request.path), options: request.overwrite ? .atomic : .withoutOverwriting)
		return imageResult(read, saved: .object([
			("path", JSON(request.path)), ("uti", JSON(source.uti)), ("mime_type", JSON(source.mimeType)),
			("bytes", JSON(source.bytes)), ("width", JSON(source.width)), ("height", JSON(source.height)),
		]))
	}

	// MARK: desktop_clipboard_write

	static func clipboardWrite(_ arguments: JSON) async throws -> ToolResult {
		let text = arguments["text"], format = arguments["format"], path = arguments["path"], paths = arguments["paths"]
		// The MCP layer enforces the exclusive forms a schema can't state, before the action runner.
		let image = format == "image" && path != nil && text == nil && paths == nil
		let files = format == "files" && paths != nil && text == nil && path == nil
		let plain = text != nil && format == nil && path == nil && paths == nil
		guard image || files || plain else {
			return ToolResult(text: "Supply text, format image with path, or format files with paths.", isError: true)
		}
		let write: @Sendable () throws -> (Delivery, [(String, JSON)])
		if files {
			guard let list = paths?.array, (1...32).contains(list.count), let strings = Optional(list.compactMap(\.string)),
			      strings.count == list.count, strings.allSatisfy(isAbsoluteClipboardPath)
			else { throw ToolError("Use format files with 1–32 absolute paths and no text or image path.") }
			try checkFileReferences(strings)
			write = {
				let urls = try Mac.clipboardFileURLs(strings)
				return (try Mac.writeClipboardFiles(urls), [("file_count", JSON(urls.count))])
			}
		} else if image {
			guard let file = path?.string, isAbsoluteClipboardPath(file) else {
				throw ToolError("Use format image with one absolute image path and no text.")
			}
			let data = try clipboardImageFile(file)
			write = {
				let source = try Mac.clipboardImageInput(data)
				return (try Mac.writeClipboardImage(data, source: source), [("source", source.json)])
			}
		} else {
			guard let value = text?.string, value.utf16.count <= 8192 else {
				throw ToolError("Clipboard text must contain at most 8192 UTF-16 code units.")
			}
			write = { (try Mac.writeClipboardText(value), []) }
		}
		var action: [(String, JSON)]
		do {
			let (delivery, extra) = try await run { try write() }
			action = [("outcome", JSON(delivery.outcome)), ("native_outcome", delivery.json), ("clipboard_changed", true)] + extra
		} catch let refusal as Refusal {
			var error: [(String, JSON)] = [("code", JSON(refusal.code)), ("message", JSON(refusal.message))]
			if let hint = refusal.hint { error.append(("hint", JSON(hint))) }
			action = [("outcome", "refused"), ("native_outcome", refusal.outcome), ("clipboard_changed", false), ("error", .object(error))]
		} catch let failure as Indeterminate {
			var error: [(String, JSON)] = [("code", JSON(failure.code)), ("message", JSON(failure.message))]
			if let hint = failure.hint { error.append(("hint", JSON(hint))) }
			action = [("outcome", "unknown"), ("native_outcome", failure.delivery.json), ("clipboard_changed", true), ("error", .object(error))]
		}
		let outcome = action[0].1.string!
		return ToolResult(text: JSON.object([("action", .object(action))]).text, outcome: outcome, isError: outcome != "completed")
	}
}
