import CoreGraphics
import Foundation
import PeekabooFoundation

extension UIAutomationService {
    /// Longest a background pointer input waits for its feedback before it proceeds without it.
    nonisolated static let agentCursorFeedbackLimit: Duration = .milliseconds(600)

    /// Shows advisory feedback before background pointer input is dispatched.
    ///
    /// Feedback cannot throw and never decides the input: dispatch continues when it returns or when
    /// `agentCursorFeedbackLimit` elapses, whichever comes first. A late feedback task keeps running alone.
    func showAgentCursorFeedback(_ feedback: @escaping @MainActor @Sendable () async -> Void) async {
        guard !(self.feedbackClient is NoopAutomationFeedbackClient) else { return }
        let gate = AgentCursorFeedbackGate()
        await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task { @MainActor in
                await feedback()
                gate.resume()
            }
            Task {
                try? await Task.sleep(for: Self.agentCursorFeedbackLimit)
                gate.resume()
            }
        }
    }

    func showAgentCursorClick(target: ClickTarget, clickType: ClickType, snapshotId: String?) async {
        await self.showAgentCursorFeedback {
            guard let point = await self.agentCursorPoint(element: target.agentCursorElementID, snapshotId: snapshotId)
                ?? target.agentCursorPoint
            else { return }
            _ = await self.feedbackClient.showClickFeedback(at: point, type: clickType, target: nil)
        }
    }

    func showAgentCursorScroll(_ request: ScrollRequest) async {
        await self.showAgentCursorFeedback {
            guard let point = await self.agentCursorPoint(element: request.target, snapshotId: request.snapshotId)
                ?? request.point
            else { return }
            _ = await self.feedbackClient.showScrollFeedback(
                at: point,
                direction: request.direction,
                amount: request.amount,
                target: nil)
        }
    }

    func showAgentCursorDrag(_ request: ExactWindowDragRequest) async {
        await self.showAgentCursorFeedback {
            _ = await self.feedbackClient.showSwipeGesture(
                from: request.from,
                to: request.to,
                duration: TimeInterval(request.durationMilliseconds) / 1000,
                target: nil)
        }
    }

    /// A held button shows as a long press that lasts until `showAgentCursorRelease`.
    func showAgentCursorHold(_ request: ExactWindowHeldPointerRequest) async {
        await self.showAgentCursorFeedback {
            _ = await self.feedbackClient.showClickFeedback(at: request.point, type: .longPress, target: nil)
        }
    }

    /// Ends a held button's long press with a single click at the same point, however the hold ended.
    func showAgentCursorRelease(_ termination: ExactWindowHeldPointerTermination?) async {
        guard let termination else { return }
        await self.showAgentCursorFeedback {
            _ = await self.feedbackClient.showClickFeedback(at: termination.receipt.point, type: .single, target: nil)
        }
    }

    /// An element target's center in its snapshot, in global screen coordinates.
    private func agentCursorPoint(element: String?, snapshotId: String?) async -> CGPoint? {
        guard let element, let snapshotId,
              let result = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
              let detected = result.elements.findById(element)
        else { return nil }
        return CGPoint(x: detected.bounds.midX, y: detected.bounds.midY)
    }
}

extension ClickTarget {
    fileprivate var agentCursorPoint: CGPoint? {
        if case let .coordinates(point) = self { return point }
        return nil
    }

    fileprivate var agentCursorElementID: String? {
        if case let .elementId(id) = self { return id }
        return nil
    }
}

private final class AgentCursorFeedbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        self.lock.lock()
        self.continuation = continuation
        self.lock.unlock()
    }

    func resume() {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume()
    }
}
