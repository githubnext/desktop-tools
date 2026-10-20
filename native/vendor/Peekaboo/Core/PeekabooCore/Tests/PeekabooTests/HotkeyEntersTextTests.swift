import Testing
@testable import PeekabooAutomationKit

/// Which chords the bridge refuses while a secure text field has keyboard focus.
struct HotkeyEntersTextTests {
    @Test
    func `Characters, Space, Option characters and Command-V enter text`() {
        for keys in ["a", "A", "1", "space", "/", "alt,e", "shift,a", "cmd,v", "cmd,shift,v", "cmd,alt,shift,v"] {
            #expect(HotkeyService.entersText(keys), "\(keys)")
        }
    }

    @Test
    func `Editing, moving, submitting and other shortcuts don't`() {
        for keys in [
            "return", "tab", "shift,tab", "escape", "delete", "forwarddelete", "left", "shift,right", "up", "down",
            "home", "end", "pageup", "pagedown", "f5", "cmd,a", "cmd,c", "cmd,x", "ctrl,a", "cmd,z",
        ] {
            #expect(!HotkeyService.entersText(keys), "\(keys)")
        }
    }
}
