import Testing
@testable import PeekabooAutomationKit

struct HotkeySelectionPolicyTests {
    @Test(arguments: ["cmd,a", "command+A", " META a ", "win,a", "windows,a", "cmdOrCtrl,a", "cmd,cmd,a"])
    func `selection policy uses the canonical hotkey parser`(_ keys: String) {
        #expect(HotkeyService.isSelectAllShortcut(keys))
    }

    @Test(arguments: [
        "cmd,b",
        "ctrl,a",
        "cmd,shift,a",
        "cmd,alt,a",
        "cmd,fn,a",
        "cmd+ctrl,a",
        "a",
        "cmd",
        "cmd,a,b",
        ""
    ])
    func `selection policy refuses other modifiers keys and malformed chords`(_ keys: String) {
        #expect(!HotkeyService.isSelectAllShortcut(keys))
    }

    @Test(arguments: ["cmd,char:61", "command+char:61"])
    func `a layout character selects all off the main thread, where no layout can be read`(_ keys: String) async {
        let classified = await Task.detached { HotkeyService.isSelectAllShortcut(keys) }.value
        #expect(classified)
    }

    @Test(arguments: ["cmd,char:62", "cmd,shift,char:61", "char:61", "cmd,char:41", "cmd,char:61,b", "cmd,char:zz"])
    func `other layout characters never select all`(_ keys: String) async {
        let classified = await Task.detached { HotkeyService.isSelectAllShortcut(keys) }.value
        #expect(!classified)
    }

    @Test func `a layout character pastes off the main thread`() async {
        let paste = await Task.detached { HotkeyService.isPasteShortcut("cmd,char:76") }.value
        let other = await Task.detached { HotkeyService.isPasteShortcut("cmd,char:63") }.value
        #expect(paste)
        #expect(!other)
    }
}
