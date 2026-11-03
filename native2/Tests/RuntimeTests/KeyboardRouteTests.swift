@testable import DesktopHost
@testable import DesktopMac
import Testing

/// Keys into a window that isn't key, and pastes into a web terminal (#226, #229).
struct KeyboardRouteTests {
	@Test
	func `key preparation names the key window and counts what it sent`() {
		#expect(KeyPreparation.notNeeded.field == nil)
		#expect(KeyPreparation.notNeeded.units == 0)
		#expect(KeyPreparation.prepared(units: 2).field == "made_key")
		#expect(KeyPreparation.prepared(units: 2).units == 2)
		#expect(KeyPreparation.prepared(units: 0).field == "already_key")
		#expect(KeyPreparation.unavailable("no chrome").field == "not_key")
		#expect(KeyPreparation.unavailable("no chrome").units == 0)
		#expect(KeyPreparation.stopped(units: 1, cause: "gone").field == "not_key")
		#expect(KeyPreparation.stopped(units: 1, cause: "gone").units == 1)
	}

	@Test
	func `a paste into a web terminal is refused before anything is sent`() {
		#expect(terminalPasteRefusal.code == "PASTE_UNVERIFIABLE_RECEIVER")
		#expect(terminalPasteRefusal.reason == "operation_unsupported")
		#expect(terminalPasteRefusal.message.hasSuffix("Nothing was pasted."))
		#expect(terminalPasteRefusal.hint?.contains("desktop_key") == true)
	}
}
