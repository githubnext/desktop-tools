import ApplicationServices
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// What turning on an app's web Accessibility tree did, sent as the response's integer.
public enum PeekabooBridgeWebAccessibilityChange: Int, Sendable {
    /// It was already on, from this host or another assistive app.
    case alreadyOn = 0
    /// This request turned it on with `AXManualAccessibility`.
    case manual = 1
    /// This request turned it on with `AXEnhancedUserInterface`, because the app rejected `AXManualAccessibility`.
    case enhancedUserInterface = 2
    /// The app accepted neither attribute, and nothing changed.
    case unsupported = 3
}

/// Chromium and Electron build their web content's Accessibility tree only once an assistive client sets
/// `AXManualAccessibility` on the application. Chrome 155 rejects that attribute and builds the tree only for
/// `AXEnhancedUserInterface`, which VoiceOver sets. That one can change how some apps animate and place their
/// windows, so it is set only when the caller allows it, for an app that ships Chromium, and only after
/// `AXManualAccessibility` was rejected. Window moves and resizes in Chrome 155 still read back exactly with it on.
enum WebAccessibilityActivation {
    private static let manualAttribute = "AXManualAccessibility"
    private static let enhancedAttribute = "AXEnhancedUserInterface"
    private static let delivery = DesktopActionOutcome.Delivery(mechanism: .accessibilityValue, mode: .background)

    private struct Generation: Hashable {
        let processIdentifier: pid_t
        let processStartIdentity: UInt64
    }

    /// App generations this host already turned it on for, or found it on; it is set at most once per launch.
    @MainActor private static var enabled: Set<Generation> = []

    /// Turns it on for this exact app generation, falling back to `AXEnhancedUserInterface` when allowed.
    @MainActor
    static func enable(
        _ identity: ApplicationProcessIdentity, allowsEnhancedUserInterface: Bool
    ) throws -> (change: PeekabooBridgeWebAccessibilityChange, outcome: DesktopActionOutcome) {
        let generation = Generation(
            processIdentifier: identity.processIdentifier, processStartIdentity: identity.processStartIdentity)
        guard SystemIdentityResolver.processStartIdentity(identity.processIdentifier) == identity.processStartIdentity
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .notFound, message: "The app quit or relaunched before its web accessibility was turned on.",
                kind: .appNotFound)
        }
        let unchanged = DesktopActionOutcome.confirmedNoChange()
        if self.enabled.contains(generation) { return (.alreadyOn, unchanged) }
        let application = AXUIElementCreateApplication(identity.processIdentifier)
        // A busy renderer must not hold the host's main thread for the default six seconds.
        AXUIElementSetMessagingTimeout(application, 1)
        if self.isOn(application, self.manualAttribute) || self.isOn(application, self.enhancedAttribute) {
            self.enabled.insert(generation)
            return (.alreadyOn, unchanged)
        }
        let status = AXUIElementSetAttributeValue(application, self.manualAttribute as CFString, kCFBooleanTrue)
        switch status {
        case .success:
            self.enabled.insert(generation)
            return (.manual, self.isOn(application, self.manualAttribute)
                ? .confirmedChange(delivery: self.delivery, unitCount: .one)
                : .dispatchedUnverified(delivery: self.delivery, evidence: .deliveryAccepted, unitCount: .one))
        case .attributeUnsupported, .notImplemented, .illegalArgument, .actionUnsupported:
            guard allowsEnhancedUserInterface else { return (.unsupported, unchanged) }
            // Chrome reports an error for this set even when it applies it, so only the readback counts.
            _ = AXUIElementSetAttributeValue(application, self.enhancedAttribute as CFString, kCFBooleanTrue)
            guard self.isOn(application, self.enhancedAttribute) else { return (.unsupported, unchanged) }
            self.enabled.insert(generation)
            return (.enhancedUserInterface, .confirmedChange(delivery: self.delivery, unitCount: .one))
        default:
            // The app may still apply a request that timed out.
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError, message: "Setting AXManualAccessibility failed (AX error \(status.rawValue)).",
                operationMayHaveCompleted: status == .cannotComplete)
        }
    }

    private static func isOn(_ application: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }
}
