import ApplicationServices
import Foundation

/// Checks that keep characters out of a focused secure text field, such as a password field, except through a fill.
public enum SecureFieldInput {
    /// The refusal for keys, typing, insertion and Paste menu commands while a secure field has keyboard focus.
    public static let refusal =
        "The focused element is a secure text field, such as a password field, so characters and pastes are refused. Nothing was sent."

    /// Whether the app's focused element is a secure text field. Safe off the main thread.
    public nonisolated static func focusIsSecure(processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
            == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        return self.string(kAXRoleAttribute, of: element) == "AXSecureTextField"
            || self.string(kAXSubroleAttribute, of: element) == "AXSecureTextField"
    }

    /// Whether a menu item pastes, whatever its localized title: its shortcut is Command-V, with or without other
    /// modifiers, or its identifier names a paste action such as `paste:` or `pasteAsPlainText:`.
    public nonisolated static func isPasteMenuItem(_ item: AXUIElement) -> Bool {
        if self.string("AXIdentifier", of: item)?.lowercased().hasPrefix("paste") == true { return true }
        guard self.string(kAXMenuItemCmdCharAttribute, of: item)?.uppercased() == "V" else { return false }
        var modifiers: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
            == .success, let flags = (modifiers as? NSNumber)?.intValue
        else { return true }
        // kAXMenuItemModifierNoCommand: the shortcut is V without Command, which doesn't paste.
        return flags & 8 == 0
    }

    private nonisolated static func string(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
