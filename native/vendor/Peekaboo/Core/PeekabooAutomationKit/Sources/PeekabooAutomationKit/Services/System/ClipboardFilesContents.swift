import Foundation

/// Advertised file references only; paths are decoded without accessing the filesystem.
public struct ClipboardFilesContents: Codable, Sendable {
    public let present: Bool
    public let files: [File]?
    public let change_count: Int

    public struct File: Codable, Sendable {
        public let url: String
        public let path: String
    }
}
