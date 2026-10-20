import CoreGraphics
import Foundation
import PeekabooFoundation

/// Samples a drag through its waypoints in order, landing exactly on each waypoint and on the end.
public enum DragPolyline {
    public static let maximumWaypointCount = 16

    /// Returns `count` points after `start`: at least one per segment, the rest shared by segment length.
    /// Returns an empty path when `count` is smaller than the number of segments.
    public static func samples(
        from start: CGPoint,
        through waypoints: [CGPoint],
        to end: CGPoint,
        count: Int) -> [CGPoint]
    {
        let vertices = [start] + waypoints + [end]
        let segments = vertices.count - 1
        guard count >= segments else { return [] }
        let lengths = (0..<segments).map { index in
            Double(hypot(vertices[index + 1].x - vertices[index].x, vertices[index + 1].y - vertices[index].y))
        }
        let total = lengths.reduce(0, +)
        let spare = count - segments
        let shares = lengths.map { total > 0 ? Double(spare) * $0 / total : Double(spare) / Double(segments) }
        var allotted = shares.map { Int($0.rounded(.down)) }
        var remaining = spare - allotted.reduce(0, +)
        // Largest remainder first, so the counts add up exactly.
        for index in shares.indices.sorted(by: {
            shares[$0] - Double(allotted[$0]) > shares[$1] - Double(allotted[$1])
        }) {
            guard remaining > 0 else { break }
            allotted[index] += 1
            remaining -= 1
        }
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for segment in 0..<segments {
            let first = vertices[segment]
            let last = vertices[segment + 1]
            let samples = allotted[segment] + 1
            for sample in 1...samples {
                let fraction = CGFloat(sample) / CGFloat(samples)
                points.append(sample == samples ? last : CGPoint(
                    x: first.x + (last.x - first.x) * fraction,
                    y: first.y + (last.y - first.y) * fraction))
            }
        }
        return points
    }
}

/// One bounded drag inside a single capture-owned window, straight or through up to 16 waypoints.
/// Coordinates are global logical points.
/// This is a separate contract from foreground drag and the fixed-point split held-pointer API.
public struct ExactWindowDragRequest: Codable, Equatable, Sendable {
    public static let durationMillisecondsRange = 1...10000
    public static let sampleCountRange = 1...96

    public let snapshotID: String
    public let target: UIAutomationTarget.ExactWindow
    public let from: CGPoint
    public let to: CGPoint
    public let durationMilliseconds: Int
    public let steps: Int
    public let button: ExactWindowHeldPointerButton
    /// Points visited in order between `from` and `to`; empty for a straight drag.
    public let waypoints: [CGPoint]

    public init(
        snapshotID: String,
        target: UIAutomationTarget.ExactWindow,
        from: CGPoint,
        to: CGPoint,
        durationMilliseconds: Int = 500,
        steps: Int = 20,
        button: ExactWindowHeldPointerButton = .left,
        waypoints: [CGPoint] = [])
    {
        self.snapshotID = snapshotID
        self.target = target
        self.from = from
        self.to = to
        self.durationMilliseconds = durationMilliseconds
        self.steps = steps
        self.button = button
        self.waypoints = waypoints
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotID, target, from, to, durationMilliseconds, steps, button, waypoints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshotID = try container.decode(String.self, forKey: .snapshotID)
        self.target = try container.decode(UIAutomationTarget.ExactWindow.self, forKey: .target)
        self.from = try container.decode(CGPoint.self, forKey: .from)
        self.to = try container.decode(CGPoint.self, forKey: .to)
        self.durationMilliseconds = try container.decode(Int.self, forKey: .durationMilliseconds)
        self.steps = try container.decode(Int.self, forKey: .steps)
        self.button = try container.decode(ExactWindowHeldPointerButton.self, forKey: .button)
        self.waypoints = try container.decodeIfPresent([CGPoint].self, forKey: .waypoints) ?? []
    }

    /// The drag samples after the press, in order; the last is `to`.
    public var samplePoints: [CGPoint] {
        DragPolyline.samples(from: self.from, through: self.waypoints, to: self.to, count: self.steps)
    }

    /// Primer, down, each drag sample, and the sole terminal up.
    public var dispatchedUnitCount: Int {
        Self.sampleCountRange.contains(self.steps) ? self.steps + 3 : 0
    }

    public func validate() throws {
        _ = try UIAutomationTarget.ExactWindow(identity: self.target.identity, bounds: self.target.bounds)
        guard SnapshotReference(rawValue: self.snapshotID) != nil,
              Self.durationMillisecondsRange.contains(self.durationMilliseconds),
              Self.sampleCountRange.contains(self.steps),
              self.target.identity.ownerProcessIdentifier > 0,
              self.target.identity.ownerProcessStartIdentity > 0,
              self.target.identity.windowID > 0, UInt32(exactly: self.target.identity.windowID) != nil,
              self.target.identity.capturedBounds == self.target.bounds,
              self.target.bounds.origin.x.isFinite, self.target.bounds.origin.y.isFinite,
              self.target.bounds.width.isFinite, self.target.bounds.height.isFinite,
              self.target.bounds.width > 0, self.target.bounds.height > 0,
              self.from.x.isFinite, self.from.y.isFinite, self.to.x.isFinite, self.to.y.isFinite,
              self.from != self.to || !self.waypoints.isEmpty,
              self.target.bounds.contains(self.from), self.target.bounds.contains(self.to),
              self.waypoints.count <= DragPolyline.maximumWaypointCount,
              self.steps > self.waypoints.count,
              self.waypoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite && self.target.bounds.contains($0) })
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Background drag requires distinct finite endpoints and at most 16 waypoints inside one " +
                    "exact snapshot window, a duration of 1...10000 milliseconds, and 1...96 samples, " +
                    "at least one per segment.",
                hint: "Capture the exact window again; use explicit foreground mode for cross-window gestures.")
        }
    }
}

@MainActor
public protocol ExactWindowDragServiceProtocol: UIAutomationServiceProtocol {
    var supportsExactWindowDrag: Bool { get }

    func dragExactWindow(
        _ request: ExactWindowDragRequest,
        boundTo processIdentity: ApplicationProcessIdentity?) async throws -> UIAutomationActionResult<Void>
}

extension UIAutomationService: ExactWindowDragServiceProtocol {
    public var supportsExactWindowDrag: Bool {
        true
    }

    public func dragExactWindow(
        _ request: ExactWindowDragRequest,
        boundTo processIdentity: ApplicationProcessIdentity? = nil) async throws -> UIAutomationActionResult<Void>
    {
        // Before the hold exists, so feedback never spends the hold's expiry budget.
        if (try? request.validate()) != nil { await self.showAgentCursorDrag(request) }
        return try await self.heldPointerLifecycle.drag(request: request, boundTo: processIdentity) {
            let detection = try await self.snapshotManager.getDetectionResult(snapshotId: request.snapshotID)
            let receipt = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: request.snapshotID,
                detectionResult: detection,
                requireExactWindow: true,
                processStartIdentityProvider: self.processStartIdentityProvider,
                exactWindowIdentityValidator: self.exactWindowIdentityValidator)
            guard receipt.exactWindow == request.target else {
                throw PeekabooError.snapshotStale("Drag target differs from its capture-owned exact-window receipt")
            }
        }
    }
}
