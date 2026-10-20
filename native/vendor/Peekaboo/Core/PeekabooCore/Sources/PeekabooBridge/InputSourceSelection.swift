import Carbon
import Foundation

enum InputSourceSelection {
    /// Selects the enabled, selectable keyboard input source with this ID, as the input menu would.
    /// Text Input Sources are changed on the main thread, where the run loop delivers their changes.
    @MainActor
    static func select(_ id: String) throws {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceID as String: id,
        ] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        guard let source = sources.first else {
            throw PeekabooBridgeErrorEnvelope(
                code: .notFound,
                message: "No enabled input source has the ID \(id)")
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "macOS refused to select the input source (status \(status))")
        }
    }
}
