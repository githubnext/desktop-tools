import AppKit
import ApplicationServices
import Foundation
import PeekabooFoundation

public struct LiteralInsertError: Codable, Sendable {
    public let code: String
    public let message: String
    public var hint: String?
    public var cause: String?

    public init(code: String, message: String, hint: String? = nil, cause: String? = nil) {
        self.code = code; self.message = message; self.hint = hint; self.cause = cause
    }
}

public struct LiteralInsertReceipt: Codable, Sendable {
    public let pid: Int32
    public let window_id: Int
    public let process_start_identity_decimal: String
}

/// Clipboard contents and the private text comparison never enter the response.
public struct LiteralInsertResult: Codable, Sendable {
    public var outcome: String
    public var native_outcome: DesktopActionOutcome?
    public let target_receipt: LiteralInsertReceipt?
    public var clipboard_changed = false
    public var clipboard_cleanup = "not_needed"
    public var clipboard_ownership = "released"
    public var consumption = "unverified"
    /// For an observed attachment paste: attachment_attribute or replacement_characters.
    public var attachment_evidence: String?
    /// For files pasted into a Finder folder: the folder, and started once every name appears there. Finder may
    /// still be copying the contents.
    public var folder: String?
    public var copy: String?
    public var requires_fresh_observation = false
    public var error: LiteralInsertError?
}

@MainActor
public protocol LiteralInsertServiceProtocol: UIAutomationServiceProtocol {
    func literalInsert(
        text: String, target: UIAutomationTarget.ExactWindow, clipboard: ClipboardService,
        checkActive: @escaping @MainActor @Sendable () throws -> Void) async throws -> LiteralInsertResult
}

/// What an attachment paste puts on the clipboard: one image, or one file reference per item.
public enum AttachmentPastePayload: Sendable {
    case image(ClipboardImageInput)
    case files(ClipboardFilesInput)

    var count: Int {
        switch self {
        case .image: 1
        case let .files(input): input.files.count
        }
    }

    var write: ClipboardWriteRequest {
        switch self {
        case let .image(image):
            ClipboardWriteRequest(representations: [.init(utiIdentifier: image.source.uti, data: image.data)])
        case let .files(input):
            ClipboardWriteRequest(fileURLs: input.files.map(\.url))
        }
    }
}

/// The refusal for a guarded attachment paste into a receiver whose text can't show the attachment.
public enum AttachmentPasteRefusal {
    public static let message =
        "This receiver can't show a pasted attachment through Accessibility, so the paste could never be confirmed and the prior clipboard could never be restored. Nothing was pasted."
    public static let hint =
        "Pass clipboard replace to paste and leave the clipboard replaced, or write it with desktop_clipboard_write and press Command-V with desktop_key."
}

/// The refusal for files whose names a Finder folder already holds: Finder would ask to replace them or keep both.
public enum FinderPasteRefusal {
    public static let suffix = "Finder would ask whether to replace it or keep both, so nothing was pasted."
    public static let hint =
        "Rename or remove the existing item, or paste into another folder. desktop_insert never answers Finder's replace dialog."

    static func message(name: String, folder: String) -> String {
        "\(name) already exists in \(folder). \(self.suffix)"
    }
}

/// Files pasted into a Finder folder: the paste is seen once every name is present there, read from the filesystem.
struct FolderPasteExpectation: Sendable {
    let folder: URL
    let names: [String]

    func present() -> Bool {
        self.names.allSatisfy { Self.exists(self.folder.appendingPathComponent($0)) }
    }

    /// The first name already in the folder, before input.
    func existing() -> String? {
        self.names.first { Self.exists(self.folder.appendingPathComponent($0)) }
    }

    /// lstat, so a dangling symbolic link counts as present, as it does for Finder.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

@MainActor
public protocol AttachmentInsertServiceProtocol: UIAutomationServiceProtocol {
    func attachmentInsert(
        _ payload: AttachmentPastePayload, replace: Bool, target: UIAutomationTarget.ExactWindow,
        clipboard: ClipboardService,
        checkActive: @escaping @MainActor @Sendable () throws -> Void) async throws -> LiteralInsertResult
}

@MainActor
private final class LiteralInsertReservation {
    var token: UUID?
    var resolved = false
}

/// What a paste should leave in the exact receiver: its text with the selection replaced and the caret after it.
private struct PasteExpectation: Sendable {
    let baseline: LiteralInsertState
    let text: String
    let location: Int
    /// Attachment characters inserted at the selection; zero for text.
    let attachments: Int

    var meaningful: Bool { !self.baseline.matches(text: self.text, location: self.location, length: 0) }

    var attachmentRange: NSRange? {
        self.attachments > 0 ? NSRange(location: self.location - self.attachments, length: self.attachments) : nil
    }

    /// nil until the receiver shows the paste. A receiver that marks attachments in its attributed text must mark
    /// every inserted character; one that marks none is judged by its replacement characters alone.
    func evidence(_ observed: LiteralInsertState?) -> String? {
        guard let observed, observed.matches(text: self.text, location: self.location, length: 0) else { return nil }
        guard self.attachments > 0 else { return "text" }
        switch observed.attachmentsMarked {
        case nil, 0: return "replacement_characters"
        case self.attachments: return "attachment_attribute"
        default: return nil
        }
    }
}

extension UIAutomationService: LiteralInsertServiceProtocol, AttachmentInsertServiceProtocol {
    public func literalInsert(
        text: String, target: UIAutomationTarget.ExactWindow, clipboard: ClipboardService,
        checkActive: @escaping @MainActor @Sendable () throws -> Void) async throws -> LiteralInsertResult
    {
        guard !text.isEmpty, text.utf16.count <= 8192, target.focusedElement != nil else {
            throw Self.literalInsertRefusal("Literal insertion requires 1–8192 UTF-16 units and an exact focused receiver.")
        }
        do {
            return try await self.operationLaneCoordinator.run(scope: .process(target.identity.processIdentity), access: .write) {
                try await self.insertLiteralText(text, target: target, clipboard: clipboard, checkActive: checkActive)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as DesktopActionFailure { throw failure }
        catch { throw Self.literalInsertRefusal("Literal insertion could not establish its read-only preflight: \(error.localizedDescription)") }
    }

    public func attachmentInsert(
        _ payload: AttachmentPastePayload, replace: Bool, target: UIAutomationTarget.ExactWindow,
        clipboard: ClipboardService,
        checkActive: @escaping @MainActor @Sendable () throws -> Void) async throws -> LiteralInsertResult
    {
        guard target.focusedElement != nil else {
            throw Self.literalInsertRefusal("Attachment insertion requires an exact focused receiver.")
        }
        do {
            return try await self.operationLaneCoordinator.run(scope: .process(target.identity.processIdentity), access: .write) {
                try await self.insertAttachments(
                    payload, replace: replace, target: target, clipboard: clipboard, checkActive: checkActive)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as DesktopActionFailure { throw failure }
        catch { throw Self.literalInsertRefusal("Attachment insertion could not establish its read-only preflight: \(error.localizedDescription)") }
    }

    private func insertLiteralText(
        _ text: String, target: UIAutomationTarget.ExactWindow, clipboard: ClipboardService,
        checkActive: @escaping @MainActor @Sendable () throws -> Void) async throws -> LiteralInsertResult
    {
        try checkActive()
        let focused = try await self.requireExactWindowKeyboardFocus(
            expectedWindowIdentity: target.identity, expectedWindowBounds: target.bounds,
            expectedFocusedElement: target.focusedElement)
        guard let retained = focused.nativeElement,
              let baseline = try await self.literalInsertState(target, retained: retained),
              let range = Range(NSRange(location: baseline.location, length: baseline.length), in: baseline.text)
        else { throw Self.literalInsertRefusal("The exact receiver's complete text and selection cannot be read safely.") }
        let expectedText = baseline.text.replacingCharacters(in: range, with: text)
        guard expectedText.utf16.count <= 65_536 else {
            throw Self.literalInsertRefusal("The intended edit exceeds the complete text verification limit.")
        }
        return try await self.pasteThroughClipboard(
            ClipboardWriteRequest(representations: ClipboardWriteRequest.textRepresentations(from: Data(text.utf8))),
            expectation: .init(baseline: baseline, text: expectedText,
                               location: baseline.location + text.utf16.count, attachments: 0),
            folder: nil, replace: false, target: target, retained: retained, clipboard: clipboard, checkActive: checkActive)
    }

    private func insertAttachments(
        _ payload: AttachmentPastePayload, replace: Bool, target: UIAutomationTarget.ExactWindow,
        clipboard: ClipboardService,
        checkActive: @escaping @MainActor @Sendable () throws -> Void) async throws -> LiteralInsertResult
    {
        try checkActive()
        let focused = try await self.requireExactWindowKeyboardFocus(
            expectedWindowIdentity: target.identity, expectedWindowBounds: target.bounds,
            expectedFocusedElement: target.focusedElement)
        guard let retained = focused.nativeElement else {
            throw Self.literalInsertRefusal("The exact focused receiver cannot be retained.")
        }
        // The route is fixed here, before any input: only a native text area shows a pasted attachment in its text,
        // and only a Finder folder shows pasted files, as new names on disk. Web content and single-line fields can't,
        // so a guarded paste into them could never release its reservation.
        if case let .files(input) = payload, Self.isFinder(target) {
            let folder = try await self.finderFolder(target, retained: retained, input: input)
            return try await self.pasteThroughClipboard(
                payload.write, expectation: nil, folder: folder, replace: replace,
                target: target, retained: retained, clipboard: clipboard, checkActive: checkActive)
        }
        var expectation: PasteExpectation?
        if target.focusedElement?.role == "AXTextArea",
           await self.receiverIsNativeText(target, retained: retained),
           let baseline = try await self.literalInsertState(target, retained: retained),
           let range = Range(NSRange(location: baseline.location, length: baseline.length), in: baseline.text)
        {
            let text = baseline.text.replacingCharacters(
                in: range, with: String(repeating: "\u{FFFC}", count: payload.count))
            guard text.utf16.count <= 65_536 else {
                throw Self.literalInsertRefusal("The intended edit exceeds the complete text verification limit.")
            }
            expectation = .init(baseline: baseline, text: text,
                                location: baseline.location + payload.count, attachments: payload.count)
        }
        guard expectation != nil || replace else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported, message: AttachmentPasteRefusal.message, hint: AttachmentPasteRefusal.hint)
        }
        return try await self.pasteThroughClipboard(
            payload.write, expectation: expectation, folder: nil, replace: replace,
            target: target, retained: retained, clipboard: clipboard, checkActive: checkActive)
    }

    /// One temporary paste into the exact receiver. A replacing paste keeps no copy of the prior clipboard and takes
    /// no reservation; otherwise the prior clipboard comes back only after the expected edit is observed.
    private func pasteThroughClipboard(
        _ write: ClipboardWriteRequest, expectation: PasteExpectation?, folder: FolderPasteExpectation? = nil,
        replace: Bool,
        target: UIAutomationTarget.ExactWindow, retained: RetainedFocusElement, clipboard: ClipboardService,
        checkActive: @escaping @MainActor @Sendable () throws -> Void) async throws -> LiteralInsertResult
    {
        let meaningful = expectation?.meaningful == true || folder != nil
        let prepared = replace ? clipboard.prepareReplacingWrite() : try clipboard.prepareTemporaryWrite(
            maximumBytes: 32 * 1024 * 1024, maximumItems: 128, maximumRepresentations: 512)
        guard let transaction = prepared as? any ClipboardTemporaryWriteClaimProviding else {
            throw Self.literalInsertRefusal("The native clipboard owner cannot retain a generation claim.")
        }
        var result = LiteralInsertResult(outcome: "refused", target_receipt: .init(
            pid: target.identity.ownerProcessIdentifier, window_id: target.identity.windowID,
            process_start_identity_decimal: String(target.identity.ownerProcessStartIdentity)))
        result.folder = folder?.folder.path
        var possibleInput = false
        var claim: GeneralPasteboardWriteClaim?
        let reservation = LiteralInsertReservation()
        do {
            try checkActive()
            try await self.validateLiteralInsertBaseline(expectation?.baseline, target: target, retained: retained)
            try Self.validateFolder(folder)
            let prepareBackgroundWindow = !Self.literalInsertTargetIsActive(target)
            try checkActive()
            let written = try transaction.writeWithClaim(write)
            claim = written.claim
            let writeClaim = written.claim
            try checkActive()
            possibleInput = true
            let input = try await self.hotkeyService.hotkey(
                keys: "cmd,v", holdDuration: 50, automationTarget: .exactWindow(target),
                clipboardClaim: written.claim, prepareBackgroundWindow: prepareBackgroundWindow, laneIsOwned: true,
                beforePrimaryKeyDown: {
                    if !replace {
                        let token = try ClipboardPasteTransactionGate.reservePaste(
                            process: target.identity.processIdentity, windowID: target.identity.windowID)
                        {
                            if reservation.resolved { return true }
                            if let folder {
                                return clipboard.literalInsertChangeCount == writeClaim.changeCount && folder.present()
                            }
                            guard meaningful, let expectation,
                                  clipboard.literalInsertChangeCount == writeClaim.changeCount else { return false }
                            do {
                                let observed = try await self.literalInsertState(
                                    target, retained: retained, attachmentRange: expectation.attachmentRange)
                                return expectation.evidence(observed) != nil
                                    && clipboard.literalInsertChangeCount == writeClaim.changeCount
                            } catch { return false }
                        }
                        reservation.token = token
                    }
                    do {
                        // Persistence can block; cancellation and ownership must still hold before V is posted.
                        try checkActive()
                        guard clipboard.literalInsertChangeCount == writeClaim.changeCount,
                              SystemIdentityResolver.processStartIdentity(target.identity.ownerProcessIdentifier)
                                == target.identity.ownerProcessStartIdentity else {
                            throw Self.literalInsertRefusal("Clipboard ownership or the original receiving process changed before paste delivery.")
                        }
                        guard prepareBackgroundWindow || Self.literalInsertTargetIsActive(target) else {
                            throw Self.literalInsertRefusal("The exact receiving app is no longer active; observe it before another insertion.")
                        }
                    } catch {
                        reservation.resolved = true
                        if let token = reservation.token { try? ClipboardPasteTransactionGate.releasePaste(token) }
                        reservation.token = nil
                        throw error
                    }
                },
                deliveryValidator: {
                    try checkActive()
                    try await self.validateLiteralInsertBaseline(expectation?.baseline, target: target, retained: retained)
                    try Self.validateFolder(folder)
                    guard prepareBackgroundWindow || Self.literalInsertTargetIsActive(target) else {
                        throw Self.literalInsertRefusal("The exact receiving app is no longer active; observe it before another insertion.")
                    }
                })
            result.native_outcome = input.outcome
            guard let outcome = input.outcome, let actual = input.targetIdentity?.exactWindow,
                  actual.identity.hasSameStableReceipt(as: target.identity), actual.bounds == target.bounds
            else {
                throw DesktopActionFailure.indeterminate(evidence: .completionUnknown,
                    message: "Literal insertion returned without its expected exact-window delivery receipt.")
            }
            possibleInput = outcome.dispatchState.mutationDispatched
            result.outcome = outcome.state == .refused ? "refused" : "unknown"
        } catch let failure as DesktopActionFailure {
            result.native_outcome = failure.outcome
            possibleInput = failure.outcome.dispatchState.mutationDispatched
            result.outcome = possibleInput ? "unknown" : "refused"
            result.error = .init(code: failure.standardErrorCode?.rawValue ?? "LITERAL_INSERT_FAILED",
                                message: failure.message, hint: failure.hint, cause: failure.causeDescription)
        } catch let error as InputDeliveryIndeterminateError {
            let failure = error.desktopActionFailure(delivery: .init(mechanism: .windowTargetedEvents, mode: .background))
            result.native_outcome = failure.outcome
            possibleInput = true
            result.outcome = "unknown"
            result.error = .init(code: "LITERAL_INSERT_FAILED", message: failure.message, hint: failure.hint, cause: failure.causeDescription)
        } catch {
            result.outcome = possibleInput ? "unknown" : "refused"
            result.error = .init(code: "LITERAL_INSERT_FAILED", message: error.localizedDescription)
        }
        result.clipboard_changed = transaction.didMutate
        result.requires_fresh_observation = possibleInput
        if possibleInput, let claim, let folder {
            // Finder creates each name as its copy begins; a large copy may still be running when all are present.
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while ContinuousClock.now < deadline {
                    try checkActive()
                    guard clipboard.literalInsertChangeCount == claim.changeCount else { break }
                    if folder.present() {
                        result.consumption = "observed"
                        result.copy = "started"
                        reservation.resolved = true
                        if let token = reservation.token {
                            do { try ClipboardPasteTransactionGate.releasePaste(token) }
                            catch {
                                result.error = .init(code: "CLIPBOARD_OWNERSHIP_RELEASE_FAILED",
                                    message: "The files appeared, but shared clipboard ownership could not be released.")
                            }
                        }
                        if result.native_outcome?.state == .dispatchedUnverified || result.native_outcome?.state == .confirmedChange {
                            result.outcome = "completed"
                        }
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                if result.error == nil {
                    result.error = .init(code: "INSERTION_UNVERIFIED", message: "The pasted files were not seen in the folder.")
                }
            }
        }
        if possibleInput, meaningful, let claim, let expectation {
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while ContinuousClock.now < deadline {
                    try checkActive()
                    guard clipboard.literalInsertChangeCount == claim.changeCount,
                          SystemIdentityResolver.processStartIdentity(target.identity.ownerProcessIdentifier)
                            == target.identity.ownerProcessStartIdentity else { break }
                    let observed: LiteralInsertState?
                    do {
                        observed = try await self.literalInsertState(
                            target, retained: retained, attachmentRange: expectation.attachmentRange)
                    } catch is CancellationError { throw CancellationError() }
                    catch { observed = nil }
                    if let evidence = expectation.evidence(observed) {
                        result.consumption = "observed"
                        if expectation.attachments > 0 { result.attachment_evidence = evidence }
                        reservation.resolved = true
                        if let token = reservation.token {
                            do { try ClipboardPasteTransactionGate.releasePaste(token) }
                            catch {
                                result.error = .init(code: "CLIPBOARD_OWNERSHIP_RELEASE_FAILED",
                                    message: "The edit was observed, but shared clipboard ownership could not be released.")
                            }
                        }
                        if result.native_outcome?.state == .dispatchedUnverified || result.native_outcome?.state == .confirmedChange {
                            result.outcome = "completed"
                        }
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch {
                // Read-only verification cannot erase delivered input or authorize a retry.
                if result.error == nil {
                    result.error = .init(code: "INSERTION_UNVERIFIED", message: "The receiver's text change was not confirmed.")
                }
            }
        }
        if replace {
            // The caller chose to leave the paste on the clipboard; the prior contents were never kept.
            if result.clipboard_changed { result.clipboard_cleanup = "left_replaced" }
            if possibleInput, result.consumption != "observed", result.error == nil {
                result.error = .init(code: "INSERTION_UNVERIFIED",
                    message: folder != nil
                        ? "Command-V was sent, but the files did not appear in the folder. The clipboard was left replaced."
                        : expectation == nil
                        ? "Command-V was sent, but this receiver can't show the attachment through Accessibility. The clipboard was left replaced."
                        : "The pasted attachment was not observed in the receiver's text. The clipboard was left replaced.",
                    hint: "Inspect the receiver, or capture it with desktop_screen, before another input or clipboard write: a Command-V still pending pastes whatever the clipboard then holds.")
            }
        } else if reservation.token == nil || result.consumption == "observed" {
            do { result.clipboard_cleanup = try transaction.cleanup().status.rawValue }
            catch {
                result.clipboard_cleanup = "failed"
                if result.error == nil {
                    result.error = .init(code: "CLIPBOARD_CLEANUP_FAILED", message: "The prior clipboard could not be restored; input delivery is reported separately.")
                }
            }
        } else {
            // Cleanup is explicit, never a deinit action. Dropping the private backup cannot expose it to a delayed Cmd+V.
            result.clipboard_cleanup = claim.map { clipboard.literalInsertChangeCount == $0.changeCount }
                == true ? "retained_unverified" : "preserved_newer_contents"
            if result.error == nil {
                result.error = .init(code: "INSERTION_UNVERIFIED",
                    message: "Cmd+V may still be pending. The previous clipboard was not restored.",
                    hint: "Inspect the exact receiver before another input; do not repeat the insertion blindly.")
            }
        }
        result.clipboard_ownership = ClipboardPasteTransactionGate.hasUnresolvedPaste ? "reserved" : "released"
        guard result.clipboard_changed else {
            throw Self.literalInsertRefusal(result.error?.message ?? "Literal insertion was refused before clipboard mutation.")
        }
        return result
    }

    /// The folder in a Finder window's path bar: a list whose items are file URLs. The bar ends at the selected
    /// item when there is one, so the folder is its last item named as the window is. Items are file reference
    /// URLs, resolved to a path here. Nil when the path bar is hidden.
    private nonisolated static func finderPathBarFolder(_ window: AXUIElement) -> URL? {
        func children(_ element: AXUIElement) -> [AXUIElement] {
            AXUIElementSetMessagingTimeout(element, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
            else { return [] }
            return (value as? [AXUIElement]) ?? []
        }
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func fileURL(_ element: AXUIElement) -> URL? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success,
                  let url = value as? URL, url.isFileURL
            else { return nil }
            return (url as NSURL).filePathURL
        }
        // The path bar sits a few levels under the window, after the sidebar and file list.
        var level = [window]
        var visited = 0
        for _ in 0..<4 {
            var next: [AXUIElement] = []
            for element in level {
                for child in children(element) {
                    visited += 1
                    if visited > 200 { return nil }
                    if string(child, kAXRoleAttribute as String) == kAXListRole as String,
                       let title = string(window, kAXTitleAttribute as String), !title.isEmpty
                    {
                        let items = children(child)
                        if items.last.flatMap(fileURL) != nil {
                            return items.last(where: { string($0, kAXValueAttribute as String) == title }).flatMap(fileURL)
                        }
                    }
                    next.append(child)
                }
            }
            level = next
        }
        return nil
    }

    private static func isFinder(_ target: UIAutomationTarget.ExactWindow) -> Bool {
        NSRunningApplication(processIdentifier: target.identity.ownerProcessIdentifier)?.bundleIdentifier
            == "com.apple.finder"
    }

    /// The folder a Finder window shows, from its AXDocument or AXURL, checked before any input: Command-V would
    /// copy into it. A field being edited, such as a name or the search field, would take the paste as text instead.
    private func finderFolder(
        _ target: UIAutomationTarget.ExactWindow, retained: RetainedFocusElement, input: ClipboardFilesInput) async throws
        -> FolderPasteExpectation
    {
        let editing: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        guard let role = target.focusedElement?.role, !editing.contains(role) else {
            throw Self.literalInsertRefusal(
                "Finder's keyboard focus is a text field, which would take the paste as text. Click the folder's file list, inspect, and try again.")
        }
        let identity = target.identity
        let location: String? = try? await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetProcessStartIdentity: identity.ownerProcessStartIdentity, seconds: 0.5)
        { () -> String? in
            let element = retained.element
            AXUIElementSetMessagingTimeout(element, 0.2)
            defer { AXUIElementSetMessagingTimeout(element, 0) }
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
            let windowElement = unsafeDowncast(window, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(windowElement, 0.2)
            defer { AXUIElementSetMessagingTimeout(windowElement, 0) }
            for attribute in [kAXDocumentAttribute as String, "AXURL"] {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(windowElement, attribute as CFString, &value) == .success else { continue }
                if let url = value as? URL { return url.absoluteString }
                if let text = value as? String { return text }
            }
            // On macOS 27 a Finder window's AXDocument is empty; its path bar's last item still names the folder.
            return Self.finderPathBarFolder(windowElement)?.absoluteString
        }
        guard let location, let url = URL(string: location), url.isFileURL else {
            throw Self.literalInsertRefusal(
                "This Finder window doesn't report its folder, so the pasted files couldn't be found afterwards. Nothing was pasted. Turn on View > Show Path Bar in Finder, which shows the folder, and try again.")
        }
        let folder = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Self.literalInsertRefusal("The Finder window's folder \(folder.path) is not a folder on disk. Nothing was pasted.")
        }
        let names = input.files.map { ($0.path as NSString).lastPathComponent }
        guard Set(names.map { $0.lowercased() }).count == names.count else {
            throw Self.literalInsertRefusal(
                "Two of the files share a name, so Finder would ask whether to replace one. Nothing was pasted.")
        }
        let expectation = FolderPasteExpectation(folder: folder, names: names)
        try Self.validateFolder(expectation)
        return expectation
    }

    /// Before input, and again at delivery: no pasted name may already be in the folder.
    private static func validateFolder(_ folder: FolderPasteExpectation?) throws {
        guard let folder, let name = folder.existing() else { return }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: FinderPasteRefusal.message(name: name, folder: folder.folder.path), hint: FinderPasteRefusal.hint)
    }

    /// Whether the receiver's ancestry proves native text, not web content; an unresolved ancestry is not.
    private func receiverIsNativeText(_ target: UIAutomationTarget.ExactWindow, retained: RetainedFocusElement) async -> Bool {
        let identity = target.identity
        return (try? await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetProcessStartIdentity: identity.ownerProcessStartIdentity, seconds: 0.5)
        {
            TextInputRoute.resolve(container: retained.element) == .nativeAX
        }) ?? false
    }
    /// Without a baseline, as for a replacing paste into unreadable text, only the exact focus is revalidated.
    private func validateLiteralInsertBaseline(
        _ baseline: LiteralInsertState?, target: UIAutomationTarget.ExactWindow, retained: RetainedFocusElement) async throws
    {
        do {
            let focus = try await self.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: target.identity, expectedWindowBounds: target.bounds,
                expectedFocusedElement: target.focusedElement)
            guard focus.nativeElement == retained else {
                throw Self.literalInsertRefusal("The exact text receiver or its selection changed before insertion.")
            }
            guard let baseline else { return }
            guard let current = try await self.literalInsertState(target, retained: retained),
                  current.matches(text: baseline.text, location: baseline.location, length: baseline.length)
            else { throw Self.literalInsertRefusal("The exact text receiver or its selection changed before insertion.") }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as DesktopActionFailure { throw failure }
        catch { throw Self.literalInsertRefusal("The exact focused receiver could not be revalidated before insertion.") }
    }

    private func literalInsertState(
        _ target: UIAutomationTarget.ExactWindow, retained: RetainedFocusElement,
        attachmentRange: NSRange? = nil) async throws -> LiteralInsertState?
    {
        guard let expected = target.focusedElement else { return nil }
        let identity = target.identity
        return try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetProcessStartIdentity: identity.ownerProcessStartIdentity, seconds: 0.2)
        {
            LiteralInsertState.read(
                expected: expected, retained: retained, target: target, attachmentRange: attachmentRange)
        }
    }

    private static func literalInsertTargetIsActive(_ target: UIAutomationTarget.ExactWindow) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == target.identity.ownerProcessIdentifier,
              application.isActive,
              SystemIdentityResolver.processStartIdentity(application.processIdentifier)
                == target.identity.ownerProcessStartIdentity else { return false }
        return true
    }

    private static func literalInsertRefusal(_ message: String) -> DesktopActionFailure {
        .preDispatchRefusal(reason: .targetUnavailable, message: message)
    }
}

private struct LiteralInsertState: Sendable {
    let text: String
    let location: Int
    let length: Int
    /// Characters the receiver marks as attachments in the requested range; nil when its attributed text is unreadable.
    var attachmentsMarked: Int?

    func matches(text: String, location: Int, length: Int) -> Bool {
        self.text.utf16.elementsEqual(text.utf16) && self.location == location && self.length == length
    }

    static func read(
        expected: FocusedElementIdentity, retained: RetainedFocusElement,
        target: UIAutomationTarget.ExactWindow, attachmentRange: NSRange? = nil) -> Self?
    {
        guard SystemIdentityResolver.processStartIdentity(target.identity.ownerProcessIdentifier) == target.identity.ownerProcessStartIdentity,
              case let .success(before) = DetachedExactWindowFocusReader.readValue(expected: expected, retainedElement: retained),
              let text = before.value, text.utf16.count <= 65_536,
              before.nativeElement == retained, target.bounds.contains(CGPoint(x: before.frame.midX, y: before.frame.midY))
        else { return nil }
        let element = retained.element
        AXUIElementSetMessagingTimeout(element, 0.05)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let selection = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(selection) == .cfRange, AXValueGetValue(selection, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              case let .success(after) = DetachedExactWindowFocusReader.readValue(expected: expected, retainedElement: retained),
              after.nativeElement == retained, let current = after.value, current.utf16.elementsEqual(text.utf16),
              target.bounds.contains(CGPoint(x: after.frame.midX, y: after.frame.midY)),
              SystemIdentityResolver.processStartIdentity(target.identity.ownerProcessIdentifier) == target.identity.ownerProcessStartIdentity
        else { return nil }
        var state = Self(text: text, location: range.location, length: range.length)
        if let attachmentRange, attachmentRange.upperBound <= text.utf16.count {
            state.attachmentsMarked = Self.attachmentsMarked(element, in: attachmentRange)
        }
        return state
    }

    /// Accessibility marks each attachment character with kAXAttachmentTextAttribute ("AXAttachment").
    private static func attachmentsMarked(_ element: AXUIElement, in range: NSRange) -> Int? {
        var span = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &span) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
            let string = value as? NSAttributedString, string.length == range.length
        else { return nil }
        var marked = 0
        string.enumerateAttribute(
            NSAttributedString.Key("AXAttachment"),
            in: NSRange(location: 0, length: string.length))
        { attachment, run, _ in
            if attachment != nil { marked += run.length }
        }
        return marked
    }
}
