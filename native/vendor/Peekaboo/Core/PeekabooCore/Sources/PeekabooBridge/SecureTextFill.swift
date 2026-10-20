import AppKit
import ApplicationServices
import Foundation
@_spi(Bridge) import PeekabooAutomationKit
import PeekabooFoundation

/// Fills one secure text field, such as a password field, with a secret the agent names or supplies.
///
/// The embedder resolves the secret: it reads a Keychain item, or asks the user before using text the agent sent.
/// The secret is typed with key events into the field that has keyboard focus, and the fill is confirmed only when
/// the field's mask has exactly one character per secret character. Nothing about the secret, not even its length,
/// is returned, logged or kept.
public struct PeekabooBridgeSecureTextFillRequest: Codable, Sendable {
    public enum Secret: Codable, Sendable, Equatable {
        /// A Keychain item the embedder reads, so the agent never sees the secret.
        case keychain(PeekabooBridgeKeychainItem)
        /// Text the agent sent, which the embedder may only use once it is allowed.
        case text(String)
    }

    public let snapshotId: String
    public let expectedWindowIdentity: WindowMutationIdentity
    public let expectedWindowBounds: CGRect
    /// The secure field, which must have keyboard focus.
    public let expectedFocusedElement: FocusedElementIdentity
    public let secret: Secret

    public init(
        snapshotId: String,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        expectedFocusedElement: FocusedElementIdentity,
        secret: Secret)
    {
        self.snapshotId = snapshotId
        self.expectedWindowIdentity = expectedWindowIdentity
        self.expectedWindowBounds = expectedWindowBounds
        self.expectedFocusedElement = expectedFocusedElement
        self.secret = secret
    }
}

/// A Keychain password item, by its attributes.
public struct PeekabooBridgeKeychainItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// `kSecClassGenericPassword`, named by its service.
        case generic
        /// `kSecClassInternetPassword`, named by its server; it fills only a web field on that host.
        case internet
    }

    public let kind: Kind
    /// The generic item's service, or the internet item's server.
    public let name: String
    public let account: String?

    public init(kind: Kind, name: String, account: String?) {
        self.kind = kind
        self.name = name
        self.account = account
    }
}

/// What the embedder is asked to authorize for one fill.
public struct PeekabooBridgeSecureTextFillContext: Sendable {
    /// The socket peer that sent the request.
    public let clientProcessIdentifier: pid_t
    public let targetProcessIdentifier: pid_t
    public let applicationName: String?
    public let bundleIdentifier: String?
    /// The host of the field's web page, when it is in a web area whose URL has one.
    public let webHost: String?
    public let secret: PeekabooBridgeSecureTextFillRequest.Secret
}

public enum PeekabooBridgeSecureTextFillAuthorization: Sendable {
    /// Type this secret.
    case fill(String)
    /// Refuse before any input, with this message.
    case refuse(String)
}

/// Refusals the client recognizes by their exact messages.
public enum SecureTextFillRefusal {
    /// Characters, typed or pasted, can reach a secure field only through a fill.
    public static let secureFocus = SecureFieldInput.refusal
    public static let notSecure = "The focused element is not a secure text field. Nothing was typed."
    public static let systemPrompt =
        "This is a system authentication prompt, which is filled only by a person. Nothing was typed."
}

@MainActor
extension PeekabooBridgeServer {
    /// Apps whose password prompts guard the system itself, including those a Keychain read raises.
    private static let systemPromptBundles: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent", "com.apple.loginwindow",
        "com.apple.coreautha",
    ]
    private static let maskCharacters: Set<Character> = ["\u{F79A}", "\u{2022}", "\u{25CF}", "*"]

    /// Refuses a request that would put characters into a focused secure field any other way than a fill.
    ///
    /// Enter, Tab, Escape, arrows, Delete and shortcuts other than paste stay allowed.
    func refuseCharactersIntoSecureFocus(_ request: PeekabooBridgeRequest) async throws {
        let process: pid_t?
        switch request.unwrappedOperationRequest {
        case let .exactWindowTargetedHotkey(payload):
            guard HotkeyService.entersText(payload.keys) else { return }
            process = pid_t(payload.expectedWindowIdentity.ownerProcessIdentifier)
        case let .targetedHotkey(payload):
            guard HotkeyService.entersText(payload.keys) else { return }
            process = pid_t(payload.targetProcessIdentifier)
        case let .hotkey(payload):
            guard HotkeyService.entersText(payload.keys) else { return }
            process = nil
        case let .exactWindowTargetedTypeActions(payload):
            guard Self.typesText(payload.actions) else { return }
            process = pid_t(payload.expectedWindowIdentity.ownerProcessIdentifier)
        case let .targetedTypeActions(payload):
            guard Self.typesText(payload.actions) else { return }
            process = pid_t(payload.targetProcessIdentifier)
        case let .exactWindowPixelFocusType(payload):
            guard Self.typesText(payload.request.actions) else { return }
            process = pid_t(payload.request.windowIdentity.ownerProcessIdentifier)
        case let .typeActions(payload):
            guard Self.typesText(payload.actions) else { return }
            process = nil
        case let .type(payload):
            guard !payload.text.isEmpty else { return }
            process = nil
        case let .literalInsert(payload):
            process = await self.snapshotWindow(payload.snapshot)?.0
        case let .attachmentInsert(payload):
            process = await self.snapshotWindow(payload.snapshot)?.0
        default:
            return
        }
        // A targeted request checks its app's focus; a global one, and one whose app is unknown, the system's.
        if TypeService.focusedElementIsSecureField(processIdentifier: process) {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .operationUnsupported, message: SecureTextFillRefusal.secureFocus)
        }
    }

    private static func typesText(_ actions: [TypeAction]) -> Bool {
        actions.contains { if case let .text(text) = $0 { !text.isEmpty } else { false } }
    }

    func handleSecureTextFill(
        _ payload: PeekabooBridgeSecureTextFillRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        guard let authorize = self.secureTextFill else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .operationUnsupported, message: "This host does not fill secure text fields.")
        }
        guard let peer else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .permissionDenied, message: "The request has no verified client.")
        }
        guard let service = try self.automationOutcomeService() else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .operationUnsupported,
                message: "This host cannot confirm secure text field fills.")
        }
        let pid = pid_t(payload.expectedWindowIdentity.ownerProcessIdentifier)
        let app = NSRunningApplication(processIdentifier: pid)
        if let bundle = app?.bundleIdentifier, Self.systemPromptBundles.contains(bundle) {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .invalidRequest, message: SecureTextFillRefusal.systemPrompt)
        }
        guard let field = Self.focusedElement(of: pid), Self.isSecure(field) else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .invalidRequest, message: SecureTextFillRefusal.notSecure)
        }
        let context = PeekabooBridgeSecureTextFillContext(
            clientProcessIdentifier: peer.processIdentifier,
            targetProcessIdentifier: pid,
            applicationName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier,
            webHost: Self.webHost(of: field),
            secret: payload.secret)
        let secret: String
        switch await authorize(context) {
        case let .refuse(message):
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .permissionDenied, message: message)
        case let .fill(value):
            secret = value
        }
        guard !secret.isEmpty, !secret.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .invalidRequest,
                message: "The password is empty or has control characters, such as newlines or tabs, which key events can't type. Nothing was typed.")
        }
        // A prompt or a Keychain read may have taken long enough for focus to move.
        guard let current = Self.focusedElement(of: pid), CFEqual(current, field) else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .targetUnavailable,
                message: "The secure field lost keyboard focus while the password was being prepared. Nothing was typed.")
        }

        let delivery = DesktopActionOutcome.Delivery(mechanism: .windowTargetedEvents, mode: .background)
        let target = ExactWindowKeyboardTarget(
            windowIdentity: payload.expectedWindowIdentity,
            windowBounds: payload.expectedWindowBounds,
            focusedElement: payload.expectedFocusedElement)
        let typed: UIAutomationActionResult<TypeResult>
        do {
            typed = try await service.typeActionsWithOutcome(
                [.clear, .text(secret)], cadence: .fixed(milliseconds: 2), snapshotId: payload.snapshotId,
                target: target)
        } catch let failure as DesktopActionFailure {
            // Failure messages can count the characters sent so far, which would reveal part of the length.
            guard failure.outcome.dispatchState.mutationDispatched else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge, reason: .operationUnsupported,
                    message: "The secure field could not take typed input. Nothing was typed.")
            }
            throw DesktopActionFailure.indeterminate(
                route: .local,
                evidence: .completionUnknown,
                message: "Typing the password stopped partway.",
                hint: "Inspect the window; clear the field before filling it again.")
        }
        guard typed.outcome?.dispatchState.mutationDispatched ?? true else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge, reason: .operationUnsupported,
                message: "The secure field refused typed input. Nothing was typed.")
        }
        let matched = await Self.masksMatch(field, length: secret.count)
        let outcome: DesktopActionOutcome = matched
            ? .confirmedChange(delivery: delivery)
            : .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted)
        return .init(
            response: .bool(matched),
            mutation: .init(outcome: outcome, target: .requestPinned))
    }

    private static func focusedElement(of pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
            == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(focused, to: AXUIElement.self)
    }

    private static func string(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        self.string(kAXRoleAttribute, of: element) == "AXSecureTextField"
            || self.string(kAXSubroleAttribute, of: element) == "AXSecureTextField"
    }

    /// The host of the nearest enclosing web area's URL.
    private static func webHost(of element: AXUIElement) -> String? {
        var current = element
        for _ in 0..<64 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = unsafeDowncast(parent, to: AXUIElement.self)
            guard self.string(kAXRoleAttribute, of: current) == "AXWebArea" else { continue }
            var url: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, "AXURL" as CFString, &url) == .success,
                  let url = url as? URL ?? (url as? String).flatMap(URL.init(string:))
            else { return nil }
            return url.host?.lowercased()
        }
        return nil
    }

    /// Whether the field shows exactly `length` mask characters; web pages update their values a little later.
    private static func masksMatch(_ field: AXUIElement, length: Int) async -> Bool {
        for attempt in 0..<15 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard let value = self.string(kAXValueAttribute, of: field),
                  value.allSatisfy(self.maskCharacters.contains)
            else { continue }
            if value.count == length { return true }
        }
        return false
    }
}
