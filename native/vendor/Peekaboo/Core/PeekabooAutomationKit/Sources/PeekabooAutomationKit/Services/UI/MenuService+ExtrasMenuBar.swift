//
//  MenuService+ExtrasMenuBar.swift
//  PeekabooCore
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation

/// One status item read from its owner's `AXExtrasMenuBar`.
struct AXExtrasMenuBarItem: @unchecked Sendable {
    let element: AXUIElement
    let ownerPID: pid_t
    let title: String?
    let itemDescription: String?
    let identifier: String?
    let frame: CGRect
    let actions: [String]
}

/// Per-process results kept in process order, so concurrent reads list the same inventory each time.
private final class AXExtrasMenuBarResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[AXExtrasMenuBarItem]]

    init(count: Int) {
        self.values = Array(repeating: [], count: count)
    }

    func set(_ index: Int, _ items: [AXExtrasMenuBarItem]) {
        self.lock.lock()
        self.values[index] = items
        self.lock.unlock()
    }

    var items: [AXExtrasMenuBarItem] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values.flatMap { $0 }
    }
}

/// Status items on hosts where `MenuBarAgent` draws the whole menu bar, so items have no WindowServer window.
@MainActor
extension MenuService {
    static let axExtrasMenuBarSource = "ax-extras"
    private static let menuBarAgentBundleIdentifier = "com.apple.MenuBarAgent"
    private nonisolated static let axExtrasMessagingTimeout: Float = 0.25
    /// NSMenu-backed items answer AXPress only after their menu closes; a longer wait would hold the lane.
    private nonisolated static let axExtrasPressTimeout: Float = 0.5

    /// Returns the Accessibility inventory when `MenuBarAgent` draws the bar as one shared window, or nil.
    /// Its windows then stand for the whole bar, and other windows at status levels are not status items.
    func axExtrasMenuBarInventory(windowExtras: [MenuExtraInfo]) -> [MenuExtraInfo]? {
        let running = NSWorkspace.shared.runningApplications
        let agents = Set(running.filter { $0.bundleIdentifier == Self.menuBarAgentBundleIdentifier }
            .map(\.processIdentifier))
        guard !agents.isEmpty,
              windowExtras.isEmpty || windowExtras.contains(where: { $0.ownerPID.map(agents.contains) ?? false })
        else { return nil }
        let owners = running.filter { $0.processIdentifier > 0 && !$0.isTerminated }
        let items = Self.axExtrasMenuBarItems(pids: owners.map(\.processIdentifier))
        guard !items.isEmpty else { return nil }
        let apps = Dictionary(owners.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let displays = self.activeDisplayBounds()
        let extras = items.map { item -> MenuExtraInfo in
            let app = apps[item.ownerPID]
            let label = sanitizedMenuText(item.title) ?? sanitizedMenuText(item.itemDescription)
            return MenuExtraInfo(
                title: label ?? sanitizedMenuText(item.identifier) ?? app?.localizedName ?? "Menu Bar Item",
                rawTitle: label,
                bundleIdentifier: app?.bundleIdentifier,
                ownerName: app?.localizedName,
                position: item.frame.origin,
                isVisible: Self.isMenuExtraFrameVisible(item.frame, displayBounds: displays),
                identifier: sanitizedMenuText(item.identifier),
                ownerPID: item.ownerPID,
                source: Self.axExtrasMenuBarSource,
                size: item.frame.size)
        }
        // Items sit on one row whose AX origins differ by fractions of a point; order them left to right.
        return extras.sorted { lhs, rhs in
            if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
            if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
            if lhs.ownerPID != rhs.ownerPID { return (lhs.ownerPID ?? 0) < (rhs.ownerPID ?? 0) }
            return (lhs.identifier ?? lhs.title) < (rhs.identifier ?? rhs.title)
        }
    }

    /// Reads every process's extras bar concurrently, so one unresponsive app costs one timeout, not one each.
    nonisolated static func axExtrasMenuBarItems(pids: [pid_t]) -> [AXExtrasMenuBarItem] {
        let results = AXExtrasMenuBarResults(count: pids.count)
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            results.set(index, Self.axExtrasMenuBarItems(pid: pids[index]))
        }
        return results.items
    }

    nonisolated static func axExtrasMenuBarItems(pid: pid_t) -> [AXExtrasMenuBarItem] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.axExtrasMessagingTimeout)
        guard let bar = Self.axElement(application, "AXExtrasMenuBar") else { return [] }
        var items: [AXExtrasMenuBarItem] = []
        func collect(_ element: AXUIElement, depth: Int) {
            guard depth < 4, items.count < 64 else { return }
            for child in Self.axChildren(element) {
                AXUIElementSetMessagingTimeout(child, Self.axExtrasMessagingTimeout)
                switch Self.axString(child, kAXRoleAttribute) {
                case "AXMenuBarItem":
                    guard let frame = Self.axFrame(child), frame.width > 0, frame.height > 0 else { continue }
                    var names: CFArray?
                    let actions = AXUIElementCopyActionNames(child, &names) == .success
                        ? (names as? [String] ?? []) : []
                    items.append(AXExtrasMenuBarItem(
                        element: child,
                        ownerPID: pid,
                        title: Self.axString(child, kAXTitleAttribute),
                        itemDescription: Self.axString(child, kAXDescriptionAttribute),
                        identifier: Self.axString(child, kAXIdentifierAttribute),
                        frame: frame,
                        actions: actions))
                case "AXGroup":
                    // MenuBarAgent hosts system items inside groups; menus under an item are not items.
                    collect(child, depth: depth + 1)
                default:
                    continue
                }
            }
        }
        collect(bar, depth: 0)
        return items
    }

    func clickAXExtrasMenuBarItem(
        _ extra: MenuExtraInfo,
        index: Int,
        evidence: DesktopSelectedLeafEvidence) async throws -> UIAutomationActionResult<ClickResult>
    {
        let processIdentity = evidence.selectedProcessIdentity
        let frame = evidence.selectedFrame
        let pid = processIdentity.processIdentifier
        let matches = Self.axExtrasMenuBarItems(pid: pid).filter { item in
            item.frame == frame && sanitizedMenuText(item.identifier) == extra.identifier
        }
        guard matches.count == 1,
              SystemIdentityResolver.processStartIdentity(pid) == processIdentity.processStartIdentity
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Menu bar item [\(index)] no longer resolves to exactly one Accessibility element of its owner.",
                hint: "Refresh menu bar items before retrying.")
                .attributed(to: processIdentity.actionTargetReceipt)
                .selectingLeaves([evidence])
        }
        let item = matches[0]
        // AXPress is the item's click; AXShowMenu only where press is absent.
        let action: String
        if item.actions.contains(kAXPressAction) {
            action = kAXPressAction
        } else if item.actions.contains(kAXShowMenuAction) {
            action = kAXShowMenuAction
        } else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Menu bar item [\(index)] exposes neither AXPress nor AXShowMenu.",
                hint: "Choose a menu bar item that exposes a supported Accessibility action.")
                .attributed(to: processIdentity.actionTargetReceipt)
                .selectingLeaves([evidence])
        }
        do {
            try Self.checkMenuBarDispatchCancellation()
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: processIdentity.actionTargetReceipt).selectingLeaves([evidence])
        }
        let delivery = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .foreground)
        let before = Set(Self.onScreenMenuSurfaces().map(\.id))
        AXUIElementSetMessagingTimeout(item.element, Self.axExtrasPressTimeout)
        let error = AXUIElementPerformAction(item.element, action as CFString)
        if error != .success {
            // An NSMenu-backed item runs its menu inside the action and replies only when the menu closes,
            // so a timeout is expected while the menu is open. Only a new menu surface below the bar shows delivery.
            let opened = error == .cannotComplete ? await Self.menuSurfaceAppeared(since: before, below: frame) : false
            guard opened else {
                throw DesktopActionFailure.indeterminate(
                    delivery: delivery,
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Menu bar item [\(index)] returned AXError \(error.rawValue) without reliable \(action) dispatch evidence.",
                    hint: "Observe the menu bar before retrying; a second press usually closes an open menu.",
                    causeDescription: "AXError \(error.rawValue)")
                    .attributed(to: processIdentity.actionTargetReceipt)
                    .selectingLeaves([evidence])
            }
        }
        return try UIAutomationActionResult(
            payload: ClickResult(
                elementDescription: "Menu bar item [\(index)]: \(extra.title)",
                location: CGPoint(x: frame.midX, y: frame.midY)),
            outcome: .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted, unitCount: .one),
            targetIdentity: DesktopTargetIdentity(processIdentity: processIdentity),
            selectedLeafEvidence: [evidence])
    }

    private nonisolated static func onScreenMenuSurfaces() -> [(id: Int, bounds: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer > 0,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { return nil }
            return (id, bounds)
        }
    }

    private static func menuSurfaceAppeared(since before: Set<Int>, below item: CGRect) async -> Bool {
        for _ in 0 ..< 5 {
            let appeared = Self.onScreenMenuSurfaces().contains { surface in
                !before.contains(surface.id) && surface.bounds.minY <= item.maxY + 64 &&
                    surface.bounds.maxX >= item.minX - 1024 && surface.bounds.minX <= item.maxX + 1024
            }
            if appeared { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private nonisolated static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private nonisolated static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private nonisolated static func axFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
