import Foundation
import PeekabooFoundation

public struct ClipboardFilesInput: Sendable {
    public let files: [ClipboardFilesContents.File]

    public static func validate(_ paths: [String]) throws -> Self {
        try Task.checkCancellation()
        guard (1...32).contains(paths.count) else {
            throw Self.refusal("Clipboard file writes require 1–32 absolute paths.")
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        let files = try paths.map { path in
            guard path.hasPrefix("/"), path.utf16.count <= 4096, !path.utf8.contains(0),
                  let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw Self.refusal("Clipboard file writes require absolute paths of at most 4096 UTF-16 units without NUL.")
            }
            // Encode literal paths without resolving links, standardizing components, or consulting the filesystem.
            let raw = "file://" + encoded
            guard let url = URL(string: raw, encodingInvalidCharacters: false), url.isFileURL,
                  url.host == nil || url.host == "", !(url as NSURL).isFileReferenceURL() else {
                throw Self.refusal("Clipboard file writes require ordinary local file references.")
            }
            return ClipboardFilesContents.File(url: raw, path: path)
        }
        let largestRead = ClipboardFilesContents(present: true, files: files, change_count: Int.max)
        guard try JSONEncoder().encode(largestRead).count <= 24_000 else {
            throw Self.refusal("Clipboard file references exceed the complete 24 KB read-result limit.")
        }
        return .init(files: files)
    }

    private static func refusal(_ message: String) -> DesktopActionFailure {
        .preDispatchRefusal(reason: .invalidRequest, message: message)
    }
}
