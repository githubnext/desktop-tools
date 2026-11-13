import AppKit
@testable import DesktopHost
import DesktopProtocol
import Testing

struct SystemUITests {
	@Test
	func `System Settings and the system's permission and password prompts are the user's`() {
		for bundle in ["com.apple.systempreferences", "com.apple.UserNotificationCenter", "com.apple.SecurityAgent"] {
			#expect(SystemUI.isSystemUI(bundleIdentifier: bundle))
		}
		#expect(!SystemUI.isSystemUI(bundleIdentifier: "com.apple.TextEdit"))
		#expect(!SystemUI.isSystemUI(bundleIdentifier: nil))
	}

	@Test
	func `agents may open, read and quit System Settings, but not send it input`() async throws {
		guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return }
		let pid = settings.processIdentifier
		let click = await SystemUI.refusal("desktop_click", arguments: .object([]), target: pid)
		#expect(click?.hasPrefix(SystemUI.code) == true)
		#expect(await SystemUI.refusal("desktop_quit", arguments: .object([]), target: pid) == nil)
		#expect(await SystemUI.refusal("desktop_inspect", arguments: .object([]), target: pid) == nil)
		#expect(await SystemUI.refusal("desktop_click", arguments: .object([]), target: getpid()) == nil)
	}
}
