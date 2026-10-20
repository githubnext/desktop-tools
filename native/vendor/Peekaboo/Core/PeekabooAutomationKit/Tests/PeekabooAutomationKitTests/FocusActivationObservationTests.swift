import AppKit
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct FocusActivationObservationTests {
    @Test
    func `An unobserved activation names the app and what to do next`() throws {
        let requested = try #require(FocusError.activationNotObserved(
            application: "TextEdit", processIdentifier: 4242, requested: true).errorDescription)
        #expect(requested.contains("TextEdit (pid 4242) did not become the active app within 3 seconds"))
        #expect(requested.contains("Activate the app, then retry"))
        #expect(!requested.contains("waiting for condition"))

        let declined = try #require(FocusError.activationNotObserved(
            application: "TextEdit", processIdentifier: 4242, requested: false).errorDescription)
        #expect(declined.contains("did not accept the activation request"))
    }

    @Test
    func `A process that does not exist is never frontmost`() {
        #expect(!FocusManagementService.isFrontmost(processIdentifier: 999_999))
    }
}
