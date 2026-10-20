import AppKit
import DesktopProtocol

/// The only module that touches macOS.
public enum Mac {
	public static func apps() async throws -> JSON { .object([("apps", [])]) }
	public static func windows(pid: Int32) async throws -> JSON { .object([("windows", [])]) }
}
