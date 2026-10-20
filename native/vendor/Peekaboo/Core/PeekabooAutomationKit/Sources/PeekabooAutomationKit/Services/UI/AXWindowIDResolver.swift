import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func copyAXWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

enum AXWindowIDResolver {
    /// Native reads used to attribute an element to the application window that hosts it.
    struct Tree {
        var windowID: (AXUIElement) -> CGWindowID?
        var attribute: (String, AXUIElement) -> CFTypeRef?
        var processIdentifier: (AXUIElement) -> pid_t?

        static var system: Self { .bounded(deadline: nil) }

        /// Every read carries a short messaging timeout; with a deadline, it also stops once that deadline passes.
        static func bounded(deadline: ContinuousClock.Instant?) -> Self {
            func admitted<T>(_ element: AXUIElement, _ read: () -> T?) -> T? {
                var timeout: Float = 0.05
                if let deadline {
                    let remaining = ContinuousClock.now.duration(to: deadline).components
                    let seconds = Float(remaining.seconds) + Float(remaining.attoseconds) / 1e18
                    guard seconds > 0 else { return nil }
                    timeout = min(timeout, seconds)
                }
                guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return nil }
                defer { AXUIElementSetMessagingTimeout(element, 0) }
                let value = read()
                return deadline.map { ContinuousClock.now < $0 } ?? true ? value : nil
            }
            return Self(
                windowID: { element in admitted(element) { AXWindowIDResolver.windowID(of: element) } },
                attribute: { name, element in
                    admitted(element) {
                        var value: CFTypeRef?
                        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                        return error == .success ? value : nil
                    }
                },
                processIdentifier: { element in
                    var processIdentifier: pid_t = 0
                    return AXUIElementGetPid(element, &processIdentifier) == .success ? processIdentifier : nil
                })
        }

        func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
            // AX attributes contain native AXUIElement values, not AXorcist Element wrappers.
            guard let value = self.attribute(name, element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    static func copyWindowID(_ element: AXUIElement, into windowID: inout CGWindowID) -> AXError {
        copyAXWindowID(element, &windowID)
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        return self.copyWindowID(element, into: &windowID) == .success ? windowID : nil
    }

    /// The window that hosts an element, and the nearest sheet between them.
    struct Owner: Equatable {
        var windowID: CGWindowID
        /// A sheet takes keyboard focus from its parent window, so keyboard input reaches this element only
        /// while this sheet is the key window.
        var sheetWindowID: CGWindowID?
    }

    /// The CGWindowID of the same-process `AXWindow` that hosts `element`.
    static func owningWindowID(of element: AXUIElement, tree: Tree = .system) -> CGWindowID? {
        self.owner(of: element, tree: tree)?.windowID
    }

    /// The same-process `AXWindow` that hosts `element`.
    ///
    /// Sheets are separate WindowServer windows that are absent from the application's AXWindows, so
    /// exact-window observations reach them only through the parent window's tree. Their content must
    /// carry that parent's identity: the AXWindow link of a sheet control names the sheet, and the
    /// controls of an Open or Save panel resolve to the Open and Save Panel Service's own window or have
    /// no AXWindow at all (kAXErrorNoValue). None of these can match the observed window, so such links
    /// are replaced by the nearest same-process `AXWindow` ancestor. Elements with no such ancestor keep
    /// their direct native window identity.
    static func owner(of element: AXUIElement, tree: Tree = .system) -> Owner? {
        guard let processIdentifier = tree.processIdentifier(element) else { return nil }
        if let link = tree.element(kAXWindowAttribute, of: element),
           tree.processIdentifier(link) == processIdentifier,
           tree.attribute(kAXRoleAttribute, link) as? String == kAXWindowRole,
           let windowID = tree.windowID(link), windowID > 0
        {
            return Owner(windowID: windowID)
        }
        var current = element
        var sheetWindowID: CGWindowID?
        for _ in 0..<64 {
            if tree.processIdentifier(current) == processIdentifier {
                let role = tree.attribute(kAXRoleAttribute, current) as? String
                if role == kAXWindowRole, let windowID = tree.windowID(current), windowID > 0 {
                    return Owner(windowID: windowID, sheetWindowID: sheetWindowID)
                }
                if role == kAXSheetRole, sheetWindowID == nil {
                    sheetWindowID = tree.windowID(current).flatMap { $0 > 0 ? $0 : nil }
                }
            }
            guard let parent = tree.element(kAXParentAttribute, of: current) else { break }
            current = parent
        }
        guard let direct = tree.windowID(element), direct > 0 else { return nil }
        return Owner(windowID: direct)
    }
}
