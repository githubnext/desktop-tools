import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeObservationTitleChurnTests: DesktopObservationBindingFixtureProviding {
    private static let detection = DesktopDetectionOptions(
        mode: .accessibility,
        requiresFreshAccessibilityTree: true)
    private static let request = DesktopObservationRequest(
        target: .pid(42, window: .id(73)),
        detection: Self.detection)

    @Test
    @MainActor
    func `a title that changes during the traversal binds by window ID and reports the newer title`() async throws {
        let observed = try Self.observation(traversedTitle: "Inbox (3)", traversedWindowID: 73)

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: Self.request,
            result: observed.result,
            requireSelectorResolutionProof: true) == nil)
        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await Self.server(provider: ObservationProvider(result: observed.result)).handleAuthorized(
                .desktopObservation(Self.request),
                peer: nil,
                permissions: Self.permissions)
        }
        guard case let .desktopObservation(response) = handled.response else {
            Issue.record("Expected a desktop observation response")
            return
        }
        #expect(response.target.window?.title == "Inbox (2)")
        #expect(response.elements?.metadata.windowContext?.windowTitle == "Inbox (3)")

        let signed = try await Self.makeBundle(
            request: .desktopObservation(Self.request),
            response: .desktopObservation(observed.result),
            target: .window(observed.identity))
        try signed.validateIntegrity()
    }

    @Test
    func `a traversed title still cannot stand in for a missing or different window ID`() throws {
        let unnamed = try Self.observation(traversedTitle: "Inbox (3)", traversedWindowID: nil)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: Self.request,
            result: unnamed.result) == "window-context window title")

        let other = try Self.observation(traversedTitle: "Inbox (2)", traversedWindowID: 74)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: Self.request,
            result: other.result) == "window-context window ID")
    }

    private static func observation(
        traversedTitle: String,
        traversedWindowID: Int?) throws -> (result: DesktopObservationResult, identity: WindowMutationIdentity)
    {
        let fixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Inbox (2)",
            index: 0,
            windowSelector: .id(73)))
        let original = fixture.result.target
        let windowProof = try #require(original.selectorResolutionProofs?.last)
        let target = ResolvedObservationTarget(
            kind: original.kind,
            app: original.app,
            window: original.window,
            bounds: original.bounds,
            detectionContext: original.detectionContext,
            captureScaleHint: original.captureScaleHint,
            selectorResolutionProofs: [windowProof],
            mutationTargetIdentity: original.mutationTargetIdentity)
        let resolved = try #require(original.detectionContext)
        let traversed = WindowContext(
            applicationName: resolved.applicationName,
            applicationBundleId: resolved.applicationBundleId,
            applicationProcessId: resolved.applicationProcessId,
            applicationProcessStartIdentity: fixture.identity.ownerProcessStartIdentity,
            windowTitle: traversedTitle,
            windowID: traversedWindowID,
            windowBounds: resolved.windowBounds,
            windowMutationIdentity: resolved.windowMutationIdentity,
            shouldFocusWebContent: Self.detection.allowWebFocusFallback,
            includeMenuBarElements: Self.detection.includeMenuBarElements,
            traversalBudget: Self.detection.traversalBudget,
            requiresFreshAccessibilityTree: true)
        let base = fixture.result
        let result = DesktopObservationResult(
            target: target,
            capture: base.capture,
            elements: ElementDetectionResult(
                snapshotId: "title-churn",
                screenshotPath: "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "AXorcist",
                    windowContext: traversed)),
            files: base.files,
            timings: base.timings,
            diagnostics: base.diagnostics,
            captureContentDigest: base.captureContentDigest)
        return (result, fixture.identity)
    }
}
