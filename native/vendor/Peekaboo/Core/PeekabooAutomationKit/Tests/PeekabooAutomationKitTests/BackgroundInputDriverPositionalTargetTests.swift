import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// Single left positional clicks use accessibility actions. Pixel right- and double-clicks use
/// exact-window routed events and are covered separately by `WindowRoutedPointerDriverTests`.
struct BackgroundInputDriverPositionalTargetTests {
    @Test(arguments: [BackgroundInputDriver.PositionalClickAction.focus, .select], [false, true])
    @MainActor
    func `positional value policy is checked before focus or selection setters`(
        action: BackgroundInputDriver.PositionalClickAction,
        allowed: Bool) async throws
    {
        let element = PositionalMockElement(
            role: "AXTextField",
            frame: CGRect(x: 20, y: 30, width: 200, height: 80),
            isFocusedSettable: true,
            isSelectedSettable: true)
        if allowed {
            let outcome = try await BackgroundInputDriver.performPositionalClickAction(
                action, on: element, allowsAccessibilityValueDelivery: true)
            // Positional focus shares element clicks' verified focus write; selection stays unread.
            #expect(outcome.state == (action == .focus ? .confirmedChange : .dispatchedUnverified))
            #expect(outcome.delivery?.mechanism == .accessibilityValue)
        } else {
            let failure = await #expect(throws: DesktopActionFailure.self) {
                try await BackgroundInputDriver.performPositionalClickAction(
                    action, on: element, allowsAccessibilityValueDelivery: false)
            }
            #expect(failure?.outcome.state == .refused)
            #expect(failure?.localizedDescription.contains("value delivery is disabled") == true)
        }
        #expect(element.setFocusedValues == (allowed && action == .focus ? [true] : []))
        #expect(element.setSelectedValues == (allowed && action == .select ? [true] : []))
        #expect(element.performedActions.isEmpty)
    }

    @Test
    @MainActor
    func `positional value opt-out retains ordinary AXPress`() async throws {
        let element = PositionalMockElement(supportedActions: [AXActionNames.kAXPressAction])
        let outcome = try await BackgroundInputDriver.performPositionalClickAction(
            .press, on: element, allowsAccessibilityValueDelivery: false)
        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.delivery?.mechanism == .accessibilityAction)
        #expect(element.performedActions == [AXActionNames.kAXPressAction])
        #expect(element.setFocusedValues.isEmpty)
        #expect(element.setSelectedValues.isEmpty)
    }

    @Test
    @MainActor
    func `focus-only resolution never presses a button or selects a row`() {
        let point = CGPoint(x: 50, y: 50)
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 80, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])
        let row = PositionalMockElement(
            role: AXRoleNames.kAXRowRole,
            frame: CGRect(x: 20, y: 20, width: 160, height: 60),
            isSelectedSettable: true)

        #expect(BackgroundInputDriver.positionalClickTarget(
            inCandidates: [button, row],
            at: point,
            button: .left)?.action == .press)
        #expect(BackgroundInputDriver.positionalFocusTarget(
            inCandidates: [button, row],
            at: point) == nil)
    }

    @Test
    @MainActor
    func `focus-only resolution skips a pressable hit and finds the editable field`() {
        let point = CGPoint(x: 50, y: 50)
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 80, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])
        let textField = PositionalMockElement(
            role: "AXTextField",
            frame: CGRect(x: 30, y: 30, width: 200, height: 40),
            isValueSettable: true,
            isFocusedSettable: true)

        let resolved = BackgroundInputDriver.positionalFocusTarget(
            inCandidates: [button, textField],
            at: point)

        #expect((resolved as? PositionalMockElement) === textField)
    }

    @Test
    @MainActor
    func `pressable hit-test element at depth 0 is pressed even when the actions attribute is empty`() {
        // Regression for the live failure: `AXUIElementCopyElementAtPosition` returns the SwiftUI
        // AXButton directly, but its `AXActionNames` *attribute* read is unsupported, so
        // `actionNames` is empty. Resolution must gate on `supportsAction` (the real actions API),
        // not on the empty `actionNames` list, and press the depth-0 hit.
        let point = CGPoint(x: 2396, y: 162)
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 2348.5, y: 150.5, width: 95, height: 24),
            supportedActions: [AXActionNames.kAXPressAction],
            advertisedActionNames: []) // AXActionNames attribute read returns nothing.

        #expect(button.actionNames.isEmpty)
        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [button],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === button)
    }

    @Test
    @MainActor
    func `pressable descendant is preferred when the hit-test container is not pressable`() {
        // SwiftUI can hit-test to a container whose pressable button is nested inside it. The
        // candidate list is ordered hit -> descendants -> ancestors, so the descendant wins.
        let point = CGPoint(x: 50, y: 50)
        let container = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let descendantButton = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 60, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [container, descendantButton],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === descendantButton)
    }

    @Test
    @MainActor
    func `descendant walk never expands containers away from the point`() {
        // System Settings' Spotlight pane: the hit is the content hosting view, and reading the app
        // list's rows grows it, pushing the button below off the point before its frame is checked.
        let point = CGPoint(x: 1020, y: 709)
        let hosting = PositionalMockElement(role: "AXGroup", frame: CGRect(x: 397, y: 116, width: 740, height: 625))
        let frameless = PositionalMockElement(role: "AXGroup")
        let scrollArea = PositionalMockElement(role: "AXScrollArea", frame: CGRect(x: 629, y: 168, width: 508, height: 573))
        let appList = PositionalMockElement(role: "AXGroup", frame: CGRect(x: 649, y: -495, width: 468, height: 767))
        let row = PositionalMockElement(role: "AXRow", frame: CGRect(x: 649, y: 0, width: 468, height: 42))
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 959.5, y: 697, width: 123.5, height: 24),
            supportedActions: [AXActionNames.kAXPressAction])
        appList.automationChildren = [row]
        scrollArea.automationChildren = [appList, button]
        frameless.automationChildren = [scrollArea]
        hosting.automationChildren = [frameless]

        let descendants = BackgroundInputDriver.descendantsBreadthFirst(
            of: hosting, containing: point, maxVisited: 256, maxDepth: 8)

        #expect(descendants.map { $0 as? PositionalMockElement }.elementsEqual(
            [frameless, scrollArea, appList, button], by: ===))
        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [hosting] + descendants,
            at: point,
            button: MouseButton.left)
        #expect((resolved?.element as? PositionalMockElement) === button)
    }

    @Test
    @MainActor
    func `press target resolves from a pressable ancestor of the hit leaf`() {
        let point = CGPoint(x: 50, y: 50)
        let leaf = PositionalMockElement(role: "AXStaticText", frame: CGRect(x: 40, y: 40, width: 20, height: 20))
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 60, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [leaf, button],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === button)
    }

    @Test
    @MainActor
    func `the authoritative hit-test element is trusted even when its frame excludes the point`() {
        // Coordinate-space quirks must not veto the element macOS resolved for the point: the
        // depth-0 hit is pressed regardless of its reported frame.
        let point = CGPoint(x: 50, y: 50)
        let hit = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 900, y: 900, width: 10, height: 10),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [hit],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .press)
        #expect((resolved?.element as? PositionalMockElement) === hit)
    }

    @Test
    @MainActor
    func `non-hit candidates that do not contain the point are skipped`() {
        let point = CGPoint(x: 50, y: 50)
        let leaf = PositionalMockElement(role: "AXStaticText", frame: CGRect(x: 40, y: 40, width: 20, height: 20))
        let strayAncestor = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 500, y: 500, width: 40, height: 40),
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [leaf, strayAncestor],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `non-hit pressable candidates with unknown frames are skipped`() {
        // Regression for Chrome web content: the hit is a non-pressable AXGroup, while traversal
        // can surface unrelated pressable descendants whose frames fail to decode. A missing frame
        // cannot prove that the descendant is under the click point.
        let point = CGPoint(x: 1117, y: 678)
        let webContainer = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 773, y: 263, width: 1136, height: 785))
        let unrelatedButton = PositionalMockElement(
            role: "AXButton",
            supportedActions: [AXActionNames.kAXPressAction])

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [webContainer, unrelatedButton],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `disabled elements are not pressable`() {
        let point = CGPoint(x: 50, y: 50)
        let disabledButton = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 30, y: 30, width: 60, height: 40),
            supportedActions: [AXActionNames.kAXPressAction],
            isEnabled: false)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [disabledButton],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `generic web containers are rejected even when they advertise press`() {
        let point = CGPoint(x: 1117, y: 678)
        for role in ["AXWebArea", "AXGroup", "AXRadioGroup"] {
            let container = PositionalMockElement(
                role: role,
                frame: CGRect(x: 1000, y: 500, width: 500, height: 500),
                supportedActions: [AXActionNames.kAXPressAction])

            let resolved = BackgroundInputDriver.positionalClickTarget(
                inCandidates: [container],
                at: point,
                button: MouseButton.left)

            #expect(resolved == nil, "\(role) must not produce a false-success background press")
        }
    }

    @Test
    @MainActor
    func `left click on a text field falls back to focusing it`() {
        let point = CGPoint(x: 50, y: 50)
        let textField = PositionalMockElement(
            role: "AXTextField",
            frame: CGRect(x: 30, y: 30, width: 200, height: 30),
            isValueSettable: true,
            isFocusedSettable: true)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [textField],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .focus)
        #expect((resolved?.element as? PositionalMockElement) === textField)
    }

    @Test
    @MainActor
    func `left click selects a writable row ancestor when the hit label has no press action`() async throws {
        let point = CGPoint(x: 1578, y: 609)
        let label = PositionalMockElement(
            role: AXRoleNames.kAXButtonRole,
            frame: CGRect(x: 1524, y: 597, width: 108, height: 24))
        let cell = PositionalMockElement(
            role: "AXCell",
            frame: CGRect(x: 1518, y: 593, width: 178, height: 32))
        let row = PositionalMockElement(
            role: AXRoleNames.kAXRowRole,
            frame: CGRect(x: 1508, y: 593, width: 198, height: 32),
            isSelectedSettable: true)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [label, cell, row],
            at: point,
            button: MouseButton.left)

        #expect(resolved?.action == .select)
        #expect((resolved?.element as? PositionalMockElement) === row)
        let outcome = try await BackgroundInputDriver.performPositionalClickAction(.select, on: row)
        #expect(row.setSelectedValues == [true])
        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(!outcome.isConfirmed)
    }

    @Test
    @MainActor
    func `pixel focus revalidates exact identity immediately before its AX write`() async throws {
        let bounds = CGRect(x: 20, y: 30, width: 200, height: 80)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: 701,
                ownerProcessStartIdentity: 7001,
                capturedBounds: bounds),
            bounds: bounds)
        let textField = PositionalMockElement(
            role: "AXTextField",
            frame: bounds,
            isFocusedSettable: true)

        await #expect(throws: PeekabooError.self) {
            _ = try await BackgroundInputDriver.performExactWindowFocusAction(
                on: textField,
                exactWindow: exactWindow,
                exactWindowIdentityValidator: { identity, currentBounds in
                    #expect(identity == exactWindow.identity)
                    #expect(currentBounds == exactWindow.bounds)
                    return false
                })
        }
        #expect(textField.setFocusedValues.isEmpty)
    }

    @Test
    @MainActor
    func `cancelled pixel focus performs no AX focused write`() async throws {
        let textField = PositionalMockElement(
            role: "AXTextField",
            frame: CGRect(x: 20, y: 30, width: 200, height: 80),
            isFocusedSettable: true)
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BackgroundInputDriver.performPositionalClickAction(.focus, on: textField)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(textField.setFocusedValues.isEmpty)
    }

    @Test
    @MainActor
    func `value settable web group does not masquerade as a focused click`() {
        // Chromium exposes full-page AXGroup containers as value/focus-settable. Setting focus on
        // that container returns success but delivers no click.
        let point = CGPoint(x: 1117, y: 678)
        let webContainer = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 773, y: 139, width: 1151, height: 909),
            isValueSettable: true,
            isFocusedSettable: true)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [webContainer],
            at: point,
            button: MouseButton.left)

        #expect(resolved == nil)
    }

    @Test
    @MainActor
    func `right click requires a show menu action and never focus-falls-back`() {
        let point = CGPoint(x: 50, y: 50)
        let textField = PositionalMockElement(
            role: "AXTextField",
            frame: CGRect(x: 30, y: 30, width: 200, height: 30),
            isValueSettable: true,
            isFocusedSettable: true)
        let menuHost = PositionalMockElement(
            role: "AXGroup",
            frame: CGRect(x: 0, y: 0, width: 400, height: 400),
            supportedActions: [AXActionNames.kAXShowMenuAction])

        let withoutMenu = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [textField],
            at: point,
            button: MouseButton.right)
        #expect(withoutMenu == nil)

        let withMenu = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [textField, menuHost],
            at: point,
            button: MouseButton.right)
        #expect(withMenu?.action == .showMenu)
        #expect((withMenu?.element as? PositionalMockElement) === menuHost)
    }

    @Test
    @MainActor
    func `right click never selects a writable row`() {
        let point = CGPoint(x: 50, y: 50)
        let row = PositionalMockElement(
            role: AXRoleNames.kAXRowRole,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isSelectedSettable: true)

        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [row],
            at: point,
            button: MouseButton.right)

        #expect(resolved == nil)
        #expect(row.setSelectedValues.isEmpty)
    }

    @Test
    @MainActor
    func `empty candidate list resolves to nothing`() {
        let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: [],
            at: CGPoint(x: 1, y: 1),
            button: MouseButton.left)
        #expect(resolved == nil)
    }

    @Test
    func `unactionable point error names the foreground escape hatch and reads as point-specific`() {
        let message = BackgroundInputDriver.noActionableElementMessage(
            at: CGPoint(x: 2396, y: 162),
            targetProcessIdentifier: 92941)
        #expect(message.contains("modifier"))
        #expect(message.contains("Nothing was clicked"))
        #expect(message.contains("(2396, 162)"))
        #expect(message.contains("92941"))
        // The message must describe the genuine "nothing pressable here" case, not claim that
        // positional background clicking is impossible.
        #expect(message.contains("pressable"))
        #expect(!message.lowercased().contains("cannot be routed"))
    }

    @Test
    func `unproven route message points to foreground`() {
        #expect(BackgroundInputDriver.unprovenWindowRouteMessage.contains("--foreground"))
    }

    @Test
    func `timed out press is a failure because delivery is unverified`() {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .operationStillRunning)

        do {
            _ = try BackgroundInputDriver.validateDetachedActionOutcome(
                outcome,
                actionName: "AXPress")
            Issue.record("Expected an unverified press failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == outcome)
            #expect(failure.outcome.evidence == .operationStillRunning)
            #expect(!failure.outcome.isConfirmed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(BackgroundInputDriver.unverifiedPressMessage.contains("synthOnly"))
    }

    @Test
    func `timed out show menu remains delivered`() throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .operationStillRunning)

        let validated = try BackgroundInputDriver.validateDetachedActionOutcome(
            outcome,
            actionName: "AXShowMenu")

        #expect(validated == outcome)
        #expect(!validated.isConfirmed)
    }

    @Test
    func `occluded window message names the pinned window and the escape hatches`() {
        let message = BackgroundInputDriver.occludedWindowMessage(at: CGPoint(x: 2396, y: 162), targetWindowID: 3279)
        #expect(message.contains("3279"))
        #expect(message.contains("(2396, 162)"))
        #expect(message.contains("sheet"))
        #expect(!message.contains("--foreground"))
    }

    @Test
    func `occluded window refusal is retry safe`() {
        let failure = BackgroundInputDriver.occludedWindowRefusal(
            at: CGPoint(x: 1, y: 2),
            targetWindowID: 3,
            resolvedWindowID: 4)
        #expect(failure.outcome.dispatchState == .none)
    }

    private static func window(_ id: Int, pid: Int = 42, layer: Int = 0, _ rect: CGRect) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
        ]
    }

    private static let parentFrame = CGRect(x: 397, y: 116, width: 740, height: 625)
    private static let sheetFrame = CGRect(x: 532, y: 241, width: 470, height: 375)
    private static let panelFrame = CGRect(x: 327, y: 204, width: 880, height: 448)

    @MainActor
    private static func isSheet(
        _ sheetID: CGWindowID,
        attachedTo parentID: CGWindowID,
        _ windows: [[String: Any]],
        listed: [CGWindowID]? = [75]) -> Bool
    {
        BackgroundInputDriver.isSheetWithoutAccessibilityWindow(
            sheetID,
            attachedTo: parentID,
            copyWindowInfo: { _, _ in windows },
            accessibilityWindowIDs: { _ in listed })
    }

    @Test @MainActor
    func `a sheet in front of its parent with no AXWindow is accepted`() {
        let accepted = Self.isSheet(756, attachedTo: 75, [Self.window(756, Self.sheetFrame), Self.window(75, Self.parentFrame)])
        #expect(accepted)
    }

    @Test @MainActor
    func `an open panel wider than its parent, on a sheet, is accepted`() {
        let windows = [Self.window(1654, Self.panelFrame), Self.window(756, Self.sheetFrame), Self.window(75, Self.parentFrame)]
        let accepted = Self.isSheet(1654, attachedTo: 75, windows)
        #expect(accepted)
    }

    @Test @MainActor
    func `an open panel whose controls name an off-screen service window is accepted`() {
        let windows = [Self.window(1654, Self.panelFrame), Self.window(756, Self.sheetFrame), Self.window(75, Self.parentFrame)]
        let accepted = Self.isSheet(1654, attachedTo: 1653, windows)
        #expect(accepted)
        // An on-screen window that the panel isn't attached to still refuses.
        let other = Self.window(9, pid: 7, CGRect(x: 0, y: 0, width: 100, height: 100))
        let refused = !Self.isSheet(1654, attachedTo: 9, [other] + windows)
        #expect(refused)
    }

    @Test @MainActor
    func `a window Accessibility lists, behind the parent, off its center, or of another app is not a sheet`() {
        let front = [Self.window(756, Self.sheetFrame), Self.window(75, Self.parentFrame)]
        let results = [
            Self.isSheet(756, attachedTo: 75, front, listed: [75, 756]),
            Self.isSheet(756, attachedTo: 75, front, listed: nil),
            Self.isSheet(756, attachedTo: 75, front.reversed()),
            Self.isSheet(756, attachedTo: 75, [Self.window(756, CGRect(x: 0, y: 241, width: 470, height: 375)), front[1]]),
            Self.isSheet(756, attachedTo: 75, [Self.window(756, pid: 7, Self.sheetFrame), front[1]]),
            Self.isSheet(756, attachedTo: 75, [Self.window(756, layer: 8, Self.sheetFrame), front[1]]),
        ]
        #expect(results == [false, false, false, false, false, false])
    }
}

@MainActor
private final class PositionalMockElement: AutomationElementRepresenting, @unchecked Sendable {
    let name: String? = nil
    let label: String? = nil
    let roleDescription: String? = nil
    let identifier: String? = nil
    let role: String?
    let subrole: String?
    let frame: CGRect?
    let value: Any? = nil
    let stringValue: String? = nil
    let actionNames: [String]
    let isValueSettable: Bool
    let isFocusedSettable: Bool
    let isSelectedSettable: Bool
    let isEnabled: Bool
    private(set) var isFocused = false
    let isOffscreen = false
    var focusedElementIdentity: FocusedElementIdentity? {
        self.role.map { role in
            FocusedElementIdentity(processIdentifier: 777, windowID: 42, role: role, frame: self.frame ?? .zero)
        }
    }
    var anchorPoint: CGPoint? {
        self.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    var automationChildren: [any AutomationElementRepresenting] = []
    var setFocusedValues: [Bool] = []
    var setSelectedValues: [Bool] = []
    var performedActions: [String] = []

    /// Actions reported by the real `AXUIElementCopyActionNames` API in production. Kept separate
    /// from `actionNames` (the attribute read) so tests can model the SwiftUI case where the
    /// attribute read is empty but the actions API reports `AXPress`.
    private let supportedActions: Set<String>

    init(
        role: String? = nil,
        subrole: String? = nil,
        frame: CGRect? = nil,
        supportedActions: Set<String> = [],
        advertisedActionNames: [String]? = nil,
        isValueSettable: Bool = false,
        isFocusedSettable: Bool = false,
        isSelectedSettable: Bool = false,
        isEnabled: Bool = true)
    {
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.supportedActions = supportedActions
        // Default: the attribute read agrees with the actions API. Pass an explicit value (e.g. [])
        // to model the attribute read diverging from the actions API.
        self.actionNames = advertisedActionNames ?? Array(supportedActions)
        self.isValueSettable = isValueSettable
        self.isFocusedSettable = isFocusedSettable
        self.isSelectedSettable = isSelectedSettable
        self.isEnabled = isEnabled
    }

    func supportsAction(_ actionName: String) -> Bool {
        self.supportedActions.contains(actionName)
    }

    func performAutomationAction(_ actionName: String) throws {
        guard self.supportedActions.contains(actionName) else {
            throw AccessibilitySystemError(.actionUnsupported)
        }
        self.performedActions.append(actionName)
    }

    func setAutomationValue(_ value: UIElementValue) throws {
        _ = value
    }

    func setAutomationFocused(_ focused: Bool) throws {
        self.setFocusedValues.append(focused)
        self.isFocused = focused
    }

    func setAutomationSelected(_ selected: Bool) throws {
        guard self.isSelectedSettable else {
            throw AccessibilitySystemError(.attributeUnsupported)
        }
        self.setSelectedValues.append(selected)
    }

    func stringAttribute(_ name: String) -> String? {
        nil
    }

    func intAttribute(_ name: String) -> Int? {
        nil
    }
}
