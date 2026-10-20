import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct UIAutomationServiceAgentCursorTests {
    @Test
    @MainActor
    func `background pointer feedback receives the resolved point before dispatch`() async {
        let feedback = StallingAgentCursorFeedbackClient(stalls: false)
        let service = UIAutomationService(feedbackClient: feedback)

        await service.showAgentCursorClick(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .double,
            snapshotId: nil)
        await service.showAgentCursorScroll(ScrollRequest(
            direction: .down,
            amount: 3,
            point: CGPoint(x: 30, y: 40),
            foreground: false))

        #expect(feedback.clicks == [CGPoint(x: 10, y: 20)])
        #expect(feedback.scrolls == [CGPoint(x: 30, y: 40)])
    }

    @Test
    @MainActor
    func `stalled feedback never holds pointer input past its limit`() async {
        let feedback = StallingAgentCursorFeedbackClient(stalls: true)
        let service = UIAutomationService(feedbackClient: feedback)
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            await service.showAgentCursorClick(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil)
        }

        #expect(feedback.clicks.count == 1)
        #expect(elapsed >= UIAutomationService.agentCursorFeedbackLimit)
        #expect(elapsed < UIAutomationService.agentCursorFeedbackLimit + .seconds(2))
        feedback.release()
    }

    @Test
    @MainActor
    func `a held pointer shows a long press, then a single click where it is released`() async throws {
        let feedback = StallingAgentCursorFeedbackClient(stalls: false)
        let service = UIAutomationService(feedbackClient: feedback)
        let point = CGPoint(x: 50, y: 60)
        let request = ExactWindowHeldPointerRequest(
            point: point,
            windowIdentity: WindowMutationIdentity(windowID: 7, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 9),
            windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            button: .left,
            expiresAfterSeconds: 2)
        let receipt = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: ExactWindowHeldPointerOwner(),
            request: request,
            expiresAt: Date().addingTimeInterval(2))

        await service.showAgentCursorHold(request)
        await service.showAgentCursorRelease(nil)
        await service.showAgentCursorRelease(ExactWindowHeldPointerTermination(
            receipt: receipt,
            reason: .expired,
            cleanupOutcome: .confirmedNoChange(),
            lifecycleDispatchedUnitCount: 2))

        #expect(feedback.clicks == [point, point])
        #expect(feedback.clickTypes == [.longPress, .single])
    }

    @Test
    @MainActor
    func `no feedback client adds no wait`() async {
        let service = UIAutomationService()
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            await service.showAgentCursorClick(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil)
        }

        #expect(elapsed < .milliseconds(100))
    }
}

@MainActor
private final class StallingAgentCursorFeedbackClient: AutomationFeedbackClient {
    private let stalls: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var clicks: [CGPoint] = []
    private(set) var clickTypes: [ClickType] = []
    private(set) var scrolls: [CGPoint] = []

    init(stalls: Bool) {
        self.stalls = stalls
    }

    func release() {
        let waiting = self.waiting
        self.waiting = []
        for continuation in waiting {
            continuation.resume()
        }
    }

    func showClickFeedback(at point: CGPoint, type: ClickType, target _: VisualizerTargetWindow?) async -> Bool {
        self.clicks.append(point)
        self.clickTypes.append(type)
        if self.stalls {
            await withCheckedContinuation { self.waiting.append($0) }
        }
        return true
    }

    func showScrollFeedback(
        at point: CGPoint,
        direction _: ScrollDirection,
        amount _: Int,
        target _: VisualizerTargetWindow?) async -> Bool
    {
        self.scrolls.append(point)
        return true
    }
}
