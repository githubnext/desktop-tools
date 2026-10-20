import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

/// Fixtures follow the macOS 11–15 Notification Center structure; later releases are unverified.
struct NotificationCenterCustomActionsTests {
    static let close = "Name:Close\nTarget:0x0\nSelector:(null)"
    static let show = "Name:Show\nTarget:0x0\nSelector:(null)"
    static let reply = "Name:Reply\nTarget:0x600000a1c000\nSelector:performReply:"
    static let banner = ["AXPress", close, show, reply, "AXScrollToVisible"]

    @Test
    func `lists named descriptors in advertised order and skips standard and unnamed actions`() {
        #expect(NotificationCenterCustomActions.listedNames(Self.banner) == ["Close", "Show", "Reply"])
        #expect(NotificationCenterCustomActions.listedNames(["AXPress", "Target:0x0", "Close"]).isEmpty)
        #expect(NotificationCenterCustomActions.attribute(Self.banner) == "Close\nShow\nReply")
        #expect(NotificationCenterCustomActions.attribute(["AXPress"]) == nil)
    }

    @Test
    func `listing is bounded and never lists an ambiguous or unreadable name`() {
        let many = (1...12).map { "Name:Action \($0)\nTarget:0x0" }
        #expect(NotificationCenterCustomActions.listedNames(many) == (1...8).map { "Action \($0)" })

        let long = "Name:" + String(repeating: "x", count: 65)
        let control = "Name:Bell\u{7}"
        let duplicated = [Self.close, "Name:Close\nTarget:0x1", Self.show, "Name:\nTarget:0x0", long, control]
        #expect(NotificationCenterCustomActions.listedNames(duplicated) == ["Show"])
        #expect(NotificationCenterCustomActions.descriptor(named: "Close", in: duplicated) == nil)
        #expect(NotificationCenterCustomActions.descriptor(named: "Show", in: duplicated) == Self.show)
    }

    @Test
    func `the reserved action form names one bounded custom action`() {
        #expect(NotificationCenterCustomActions.requestedName("AXCustomAction:Close") == "Close")
        #expect(NotificationCenterCustomActions.requestedName("AXCustomAction:Mark as Read") == "Mark as Read")
        #expect(NotificationCenterCustomActions.requestedName("AXCustomAction:") == nil)
        #expect(NotificationCenterCustomActions.requestedName("AXCustomAction:Close\nTarget:0x0") == nil)
        #expect(NotificationCenterCustomActions.requestedName("Close") == nil)

        #expect(UIAutomationService.isValidActionName("AXCustomAction:Mark as Read"))
        #expect(!UIAutomationService.isValidActionName("AXCustomAction:"))
        #expect(!UIAutomationService.isValidActionName("Name:Close\nTarget:0x0"))
        #expect(UIAutomationService.isValidActionName("AXPress"))
    }

    @Test
    func `only the Notification Center executable lists custom actions`() {
        #expect(!NotificationCenterCustomActions.isNotificationCenter(getpid()))
        #expect(!NotificationCenterCustomActions.isNotificationCenter(0))
        #expect(!NotificationCenterCustomActions.isNotificationCenter(-1))
    }

    @MainActor
    @Test
    func `performs the listed descriptor and reports the requested name`() async throws {
        let driver = RecordingActionInputDriver(allowsElementActions: true)
        let service = try await Self.service(driver: driver) { _, _ in Self.banner }

        let result = try await service.performActionWithOutcome(
            target: "B1",
            actionName: "AXCustomAction:Close",
            snapshotId: SnapshotReferenceFixtures.first.rawValue)

        #expect(driver.performedActionNames == [Self.close])
        #expect(result.payload.actionName == "AXCustomAction:Close")
    }

    @MainActor
    @Test
    func `refuses custom actions before dispatch outside Notification Center or when unlisted`() async throws {
        let driver = RecordingActionInputDriver(allowsElementActions: true)
        let outside = try await Self.service(driver: driver) { _, _ in nil }
        let ambiguous = try await Self.service(driver: driver) { _, _ in [Self.close, "Name:Close\nTarget:0x1"] }

        for (service, actionName) in [
            (outside, "AXCustomAction:Close"),
            (ambiguous, "AXCustomAction:Close"),
            (try await Self.service(driver: driver) { _, _ in Self.banner }, "AXCustomAction:Snooze"),
        ] {
            let failure = await #expect(throws: (any Error).self) {
                _ = try await service.performActionWithOutcome(
                    target: "B1",
                    actionName: actionName,
                    snapshotId: SnapshotReferenceFixtures.first.rawValue)
            }
            if let failure = failure as? DesktopActionFailure {
                #expect(failure.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            }
        }
        #expect(driver.performActionCallCount == 0)
    }

    @MainActor
    private static func service(
        driver: RecordingActionInputDriver,
        descriptors: @escaping @MainActor @Sendable (AutomationElement, pid_t) -> [String]?) async throws
        -> UIAutomationService
    {
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let detected = DetectedElement(
            id: "B1",
            type: .button,
            label: "Notification",
            bounds: CGRect(x: 10, y: 10, width: 80, height: 24))
        let detectionResult = ElementDetectionResult(
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            screenshotPath: "",
            elements: DetectedElements(buttons: [detected]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: getpid(),
                    applicationProcessStartIdentity: processStartIdentity)))
        return try await UIAutomationService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: driver,
            automationElementResolver: FixedActionAutomationElementResolver(),
            exactSnapshotElementMatcher: FixedActionAutomationElementResolver.acceptsStandIn,
            processStartIdentityProvider: { _ in processStartIdentity },
            customActionDescriptors: descriptors)
    }
}
