import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

struct DetachedExactWindowFocusWindowTests {
    private let first = AXUIElementCreateApplication(-101)
    private let second = AXUIElementCreateApplication(-102)
    private let third = AXUIElementCreateApplication(-103)

    @Test(arguments: [
        AXError.cannotComplete,
        .invalidUIElement,
        .apiDisabled,
        .noValue,
        .attributeUnsupported,
        .failure,
    ])
    func `inventory errors retain native status without probing identifiers`(error: AXError) {
        let result = DetachedExactWindowFocusReader.targetWindow(
            expectedWindowID: 42,
            inventory: .init(error: error, value: [self.first]),
            copyWindowID: { _, _ in Issue.record("Failed inventory must not trigger ID reads"); return .success })
        #expect(throws: FocusedElementReceiptError.windowObservationFailed(
            stage: .inventory,
            errorCode: error.rawValue))
        {
            try result.get()
        }
    }

    @Test
    func `missing and malformed inventories are not reported as different windows`() {
        let observations: [AXDescriptorReader.SingleAttributeRead?] = [
            nil,
            .init(error: .success, value: nil),
            .init(error: .success, value: "not an array"),
            .init(error: .success, value: [self.first, "not a window"] as [Any]),
        ]
        for inventory in observations {
            let result = DetachedExactWindowFocusReader.targetWindow(
                expectedWindowID: 42,
                inventory: inventory,
                copyWindowID: { _, _ in
                    Issue.record("Malformed inventory must not trigger ID reads"); return .success
                })
            #expect(throws: FocusedElementReceiptError.windowObservationFailed(stage: .inventory, errorCode: nil)) {
                try result.get()
            }
        }
    }

    @Test(arguments: [false, true])
    func `fully readable inventory distinguishes target absence`(empty: Bool) {
        var reads = 0
        let result = DetachedExactWindowFocusReader.targetWindow(
            expectedWindowID: 42,
            inventory: .init(error: .success, value: empty ? [] : [self.first, self.second]),
            copyWindowID: { _, id in reads += 1; id = CGWindowID(50 + reads); return .success })
        #expect(throws: FocusedElementReceiptError.windowNotFound) { try result.get() }
        #expect(reads == (empty ? 0 : 2))
    }

    @Test(arguments: [AXError.cannotComplete, .success])
    func `unresolved inventory identifiers are retained only when target is not found`(error: AXError) throws {
        for hasTarget in [false, true] {
            var readElements: [AXUIElement] = []
            let result = DetachedExactWindowFocusReader.targetWindow(
                expectedWindowID: 42,
                inventory: .init(error: .success, value: [self.first, self.second, self.third]),
                copyWindowID: { element, id in
                    readElements.append(element)
                    if CFEqual(element, self.first) {
                        return error
                    }
                    if CFEqual(element, self.second) {
                        id = hasTarget ? 42 : 43; return .success
                    }
                    return .invalidUIElement
                })
            if hasTarget {
                #expect(try CFEqual(result.get(), self.second))
                #expect(readElements.count == 2)
            } else {
                #expect(throws: FocusedElementReceiptError.windowObservationFailed(
                    stage: .inventoryWindowID, errorCode: error == .success ? nil : error.rawValue))
                {
                    try result.get()
                }
                #expect(readElements.count == 3)
            }
            #expect(CFEqual(readElements[0], self.first))
            #expect(CFEqual(readElements[1], self.second))
        }
    }

    @Test
    func `an unresolved owner is unreadable rather than mismatched`() {
        #expect(throws: FocusedElementReceiptError.windowObservationFailed(stage: .owningWindow, errorCode: nil)) {
            try DetachedExactWindowFocusReader.validateOwningWindow(nil, expectedWindowID: 42).get()
        }
    }

    @Test(arguments: [CGWindowID(42), 99])
    func `the resolved owner establishes a match or mismatch`(actual: CGWindowID) throws {
        let owner = AXWindowIDResolver.Owner(windowID: actual, sheetWindowID: 43)
        let result = DetachedExactWindowFocusReader.validateOwningWindow(owner, expectedWindowID: 42)
        if actual == 42 {
            #expect(try result.get() == owner)
        } else {
            #expect(throws: FocusedElementReceiptError.windowMismatch) { try result.get() }
        }
    }

    @Test
    func `a receiver inside a sheet needs that sheet as the key window`() {
        let inSheet = ExactWindowFocusSnapshot(processIdentifier: 7, windowID: 42, sheetWindowID: 43, frame: .zero)
        let inWindow = ExactWindowFocusSnapshot(processIdentifier: 7, windowID: 42, frame: .zero)
        let key = { (processIdentifier: pid_t, windowID: Int, isSheet: Bool) in
            ExactKeyWindowSnapshot(
                processIdentifier: processIdentifier, windowID: windowID, isSheet: isSheet, hasAttachedSheet: false)
        }
        #expect(key(7, 43, true).isKey(processIdentifier: 7, windowID: 42, focused: inSheet))
        #expect(!key(8, 43, true).isKey(processIdentifier: 7, windowID: 42, focused: inSheet))
        #expect(!key(7, 44, true).isKey(processIdentifier: 7, windowID: 42, focused: inSheet))
        #expect(!key(7, 42, false).isKey(processIdentifier: 7, windowID: 42, focused: inSheet))
        #expect(key(7, 42, false).isKey(processIdentifier: 7, windowID: 42, focused: inWindow))
        #expect(!key(7, 43, true).isKey(processIdentifier: 7, windowID: 42, focused: inWindow))
    }

    @Test(arguments: [
        FocusedElementReceiptError.WindowObservationStage.inventory, .inventoryWindowID, .owningWindow, .owningWindowID,
    ])
    func `public diagnostic names only the AX stage and optional native error`(
        stage: FocusedElementReceiptError.WindowObservationStage)
    {
        for code: Int32? in [nil, AXError.cannotComplete.rawValue] {
            let message = FocusedElementReceiptError.windowObservationFailed(stage: stage, errorCode: code)
                .localizedDescription
            #expect(message.contains(stage.rawValue))
            #expect(!message.contains("belongs to a different window"))
            if let code {
                #expect(message.contains("AX error \(code)"))
            }
        }
    }
}
