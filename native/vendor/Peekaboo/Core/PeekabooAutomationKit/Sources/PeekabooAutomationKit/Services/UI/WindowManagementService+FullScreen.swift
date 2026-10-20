@preconcurrency import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

/// Enters or leaves native full screen for one exact window.
@MainActor
public protocol WindowFullScreenProviding: Sendable {
    func setWindowFullScreenActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        fullScreen: Bool) async throws -> DesktopActionResult<Void>

    /// Reads AXFullScreen from the window that still has this ID and process generation; nil when unreadable.
    func windowFullScreenState(windowID: Int, expectedIdentity: WindowMutationIdentity) async -> Bool?
}

extension WindowManagementService: WindowFullScreenProviding {
    public func setWindowFullScreenActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        fullScreen: Bool) async throws -> DesktopActionResult<Void>
    {
        let action = fullScreen ? "enter full screen" : "exit full screen"
        let outcome = try await WindowManagementActionOutcome.perform(action: action) {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                guard expectedIdentity.isMinimized != true else {
                    throw PeekabooError.invalidInput("Restore the minimized window before changing full screen")
                }
                let window = try await self.element(for: target)
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
                guard let current = window.isFullScreen() else {
                    throw OperationError.interactionFailed(
                        action: action,
                        reason: "The window does not report AXFullScreen, so it does not support native full screen")
                }
                if current == fullScreen {
                    return WindowManagementActionOutcome.confirmedNoChange
                }

                // Choose one route from read-only evidence; a native failure never selects the other.
                let delivery: DesktopActionOutcome.Delivery
                if window.isAttributeSettable(named: AXAttributeNames.kAXFullScreenAttribute) {
                    delivery = WindowManagementActionOutcome.backgroundValueDelivery
                    guard window.setFullScreen(fullScreen) == .success else {
                        throw OperationError.interactionFailed(
                            action: action,
                            reason: "Setting AXFullScreen failed")
                    }
                } else if let button = window.fullScreenButton() {
                    delivery = WindowManagementActionOutcome.backgroundActionDelivery
                    // The green button toggles, so it is pressed only when the state differs.
                    guard AXUIElementPerformAction(button.underlyingElement, kAXPressAction as CFString) == .success
                    else {
                        throw OperationError.interactionFailed(
                            action: action,
                            reason: "Pressing the window's full screen button failed")
                    }
                } else {
                    throw OperationError.interactionFailed(
                        action: action,
                        reason: "The window exposes neither a settable AXFullScreen nor a full screen button")
                }
                do {
                    guard try await self.waitForWindowFullScreen(
                        window,
                        fullScreen: fullScreen,
                        expectedIdentity: expectedIdentity)
                    else {
                        throw WindowManagementActionOutcome.suspectedNoop(
                            action: action,
                            delivery: delivery,
                            dispatchCount: 1)
                    }
                } catch let failure as DesktopActionFailure {
                    throw failure
                } catch {
                    throw WindowManagementActionOutcome.dispatchedUnverified(
                        action: action,
                        delivery: delivery,
                        dispatchCount: 1,
                        cause: error)
                }
                return WindowManagementActionOutcome.confirmedChange(delivery: delivery, dispatchCount: 1)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }

    public func windowFullScreenState(windowID: Int, expectedIdentity: WindowMutationIdentity) async -> Bool? {
        guard windowID == expectedIdentity.windowID,
              SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
              let window = try? await self.element(for: .windowId(windowID)),
              self.windowIdentityService.getWindowID(from: window).map(Int.init) == windowID
        else {
            return nil
        }
        return window.isFullScreen()
    }

    /// The transition animates for most of a second, and bounds change on the way, so only
    /// the window ID and process generation pin the window here.
    private func waitForWindowFullScreen(
        _ window: Element,
        fullScreen: Bool,
        expectedIdentity: WindowMutationIdentity) async throws -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
                  self.windowIdentityService.getWindowID(from: window).map(Int.init) == expectedIdentity.windowID
            else {
                throw PeekabooError.commandFailed(
                    "Window \(expectedIdentity.windowID) changed owner/process generation during full screen")
            }
            if window.isFullScreen() == fullScreen {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
