@testable import DesktopMac
import Foundation
import Testing

struct DialogPathTests {
	@Test
	func `a folder is chosen as the panel's directory, and a new file name in an existing one`() throws {
		let folder = FileDialogPathChoice.canonical(NSTemporaryDirectory())
		let chosen = try FileDialogPathChoice(folder)
		#expect(chosen.directory == folder && chosen.fileName == nil)
		let file = try FileDialogPathChoice(folder + "/not-there-\(UUID()).rtf")
		#expect(file.directory == folder && file.fileName?.hasSuffix(".rtf") == true)
		#expect(file.path == folder + "/" + file.fileName!)
	}

	@Test
	func `a path in a missing folder is refused before input`() {
		#expect(throws: Refusal.self) { try FileDialogPathChoice("/no-such-folder-\(UUID())/name.txt") }
	}
}
