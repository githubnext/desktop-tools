import AppKit
import Foundation
import PeekabooFoundation
import UniformTypeIdentifiers

/// Representation of a single pasteboard payload.
public struct ClipboardRepresentation: Sendable {
    public let utiIdentifier: String
    public let data: Data

    public init(utiIdentifier: String, data: Data) {
        self.utiIdentifier = utiIdentifier
        self.data = data
    }
}

/// Request to write multiple representations to the clipboard.
public struct ClipboardWriteRequest: Sendable {
    public var representations: [ClipboardRepresentation]
    public var alsoText: String?
    public var allowLarge: Bool
    /// When set, one pasteboard item per file URL replaces the representations.
    public var fileURLs: [String] = []

    /// One public.file-url item per URL, in order.
    public init(fileURLs: [String]) {
        self.representations = []
        self.alsoText = nil
        self.allowLarge = false
        self.fileURLs = fileURLs
    }

    public init(
        representations: [ClipboardRepresentation],
        alsoText: String? = nil,
        allowLarge: Bool = false)
    {
        self.representations = representations
        self.alsoText = alsoText
        self.allowLarge = allowLarge
    }
}

extension ClipboardWriteRequest {
    public static func textRepresentations(from data: Data) -> [ClipboardRepresentation] {
        [
            ClipboardRepresentation(utiIdentifier: UTType.plainText.identifier, data: data),
            ClipboardRepresentation(utiIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: data),
        ]
    }
}

/// Result returned after reading the clipboard.
public struct ClipboardReadResult: Sendable {
    public let utiIdentifier: String
    public let data: Data
    public let textPreview: String?

    public init(utiIdentifier: String, data: Data, textPreview: String?) {
        self.utiIdentifier = utiIdentifier
        self.data = data
        self.textPreview = textPreview
    }
}

/// A complete, generation-bound plain-text read; absence is distinct from an empty string.
public struct ClipboardTextContents: Codable, Sendable {
    public let present: Bool
    public let text: String?
    public let change_count: Int
}

/// Possible errors thrown by the clipboard service.
public enum ClipboardServiceError: LocalizedError, Sendable {
    case empty
    case sizeExceeded(current: Int, limit: Int)
    case slotNotFound(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Clipboard is empty."
        case let .sizeExceeded(current, limit):
            "Clipboard write blocked: size \(current) bytes exceeds \(limit) bytes. Use allowLarge to override."
        case let .slotNotFound(slot):
            "Clipboard slot '\(slot)' not found."
        case let .writeFailed(reason):
            "Failed to write to clipboard: \(reason)"
        }
    }
}

/// Protocol describing clipboard operations.
@MainActor
public protocol ClipboardServiceProtocol: Sendable {
    func get(prefer uti: UTType?) throws -> ClipboardReadResult?
    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult
    func clear()
    func save(slot: String) throws
    func restore(slot: String) throws -> ClipboardReadResult
}

/// Additive capability for clipboard mutations that retain canonical action semantics.
@MainActor
public protocol ClipboardServiceActionResultProviding: ClipboardServiceProtocol {
    func setActionResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult>
    func clearActionResult() throws -> DesktopActionResult<Void>
    func restoreActionResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult>
}

/// Shared clipboard mutation policy used by services and result consumers.
public enum ClipboardMutationResultSemantics {
    public static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .clipboardTransaction,
        mode: .foreground)

    public static func requireSuccessfulOutcome(
        _ outcome: DesktopActionOutcome?,
        operation: String) throws -> DesktopActionOutcome
    {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                delivery: self.delivery,
                evidence: .completionUnknown,
                message: "\(operation) returned without a canonical clipboard outcome.",
                hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.")
        }
        return try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            outcome,
            policy: .confirmedOrDispatched(requiring: self.delivery.mode),
            operation: operation,
            missingOutcomeMessage: "\(operation) returned without a canonical clipboard outcome.",
            rejectedOutcomeMessage: "\(operation) did not return a successful clipboard outcome.",
            missingOutcomeHint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.")
    }

    public static func postWriteFailure(_ error: any Error, operation: String) -> DesktopActionFailure {
        .indeterminate(
            delivery: self.delivery,
            evidence: .completionUnknown,
            message: "\(operation) may have changed the clipboard, but post-write processing failed.",
            hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.",
            causeDescription: error.localizedDescription)
    }
}

extension ClipboardServiceProtocol {
    public func setResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult> {
        if let provider = self as? any ClipboardServiceActionResultProviding {
            return try provider.setActionResult(request)
        }
        guard !request.representations.isEmpty else {
            throw ClipboardMutationResultOwner.preDispatchFailure(
                ClipboardServiceError.writeFailed("No representations provided."),
                operation: "Clipboard set")
        }
        return try ClipboardMutationResultOwner.performLegacy(
            operation: "Clipboard set",
            mutation: { try self.set(request) })
    }

    public func clearResult() throws -> DesktopActionResult<Void> {
        if let provider = self as? any ClipboardServiceActionResultProviding {
            return try provider.clearActionResult()
        }
        self.clear()
        return DesktopActionResult(
            outcome: .dispatchedUnverified(
                delivery: ClipboardMutationResultSemantics.delivery,
                evidence: .deliveryAccepted))
    }

    public func restoreResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult> {
        if let provider = self as? any ClipboardServiceActionResultProviding {
            return try provider.restoreActionResult(slot: slot)
        }
        guard !slot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardMutationResultOwner.preDispatchFailure(
                ClipboardServiceError.slotNotFound(slot),
                operation: "Clipboard restore")
        }
        return try ClipboardMutationResultOwner.performLegacy(
            operation: "Clipboard restore",
            mutation: { try self.restore(slot: slot) })
    }
}

private enum ClipboardMutationResultOwner {
    static func perform<Payload: Sendable>(
        operation: String,
        mutation: (inout Bool) throws -> Payload,
        verify: (Payload) throws -> Bool) throws -> DesktopActionResult<Payload>
    {
        var didDispatch = false
        do {
            let payload = try mutation(&didDispatch)
            guard didDispatch else {
                throw DesktopActionFailure.indeterminate(
                    delivery: ClipboardMutationResultSemantics.delivery,
                    evidence: .completionUnknown,
                    message: "\(operation) completed without recording clipboard dispatch.",
                    hint: "Inspect the clipboard before retrying; replaying may overwrite newer contents.")
            }
            let outcome: DesktopActionOutcome = try verify(payload)
                ? .confirmedChange(
                    delivery: ClipboardMutationResultSemantics.delivery)
                : .dispatchedUnverified(
                    delivery: ClipboardMutationResultSemantics.delivery,
                    evidence: .deliveryAccepted)
            return DesktopActionResult(payload: payload, outcome: outcome)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            if didDispatch {
                throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: operation)
            }
            throw self.preDispatchFailure(error, operation: operation)
        }
    }

    static func performLegacy<Payload: Sendable>(
        operation: String,
        mutation: () throws -> Payload) throws -> DesktopActionResult<Payload>
    {
        do {
            let payload = try mutation()
            return DesktopActionResult(
                payload: payload,
                outcome: .dispatchedUnverified(
                    delivery: ClipboardMutationResultSemantics.delivery,
                    evidence: .deliveryAccepted))
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as ClipboardServiceError {
            switch error {
            case .empty, .sizeExceeded, .slotNotFound:
                throw self.preDispatchFailure(error, operation: operation)
            case .writeFailed:
                throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: operation)
            }
        } catch {
            throw ClipboardMutationResultSemantics.postWriteFailure(error, operation: operation)
        }
    }

    static func preDispatchFailure(_ error: any Error, operation: String) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .invalidRequest,
            message: "\(operation) was refused before dispatch.",
            hint: "Correct the clipboard request before retrying.",
            causeDescription: error.localizedDescription)
    }
}

/// Default implementation backed by NSPasteboard.
@MainActor
public final class ClipboardService: ClipboardServiceActionResultProviding, ClipboardTemporaryWriteProviding,
ClipboardReadAccessProviding {
    private let pasteboard: NSPasteboard
    private let sizeLimit: Int
    private let readAccessStatusReader: @MainActor (NSPasteboard) -> ClipboardReadAccessStatus
    private var slots: [String: [ClipboardRepresentation]] = [:]

    public convenience init(
        pasteboard: NSPasteboard = .general,
        sizeLimit: Int = ClipboardPayloadBuilder.defaultSizeLimit)
    {
        self.init(pasteboard: pasteboard, sizeLimit: sizeLimit, readAccessStatusReader: Self.nativeReadAccessStatus)
    }

    init(
        pasteboard: NSPasteboard,
        sizeLimit: Int = ClipboardPayloadBuilder.defaultSizeLimit,
        readAccessStatusReader: @escaping @MainActor (NSPasteboard) -> ClipboardReadAccessStatus)
    {
        self.pasteboard = pasteboard
        self.sizeLimit = sizeLimit
        self.readAccessStatusReader = readAccessStatusReader
    }

    public func readAccessStatus() -> ClipboardReadAccessStatus {
        self.readAccessStatusReader(self.pasteboard)
    }

    private static func nativeReadAccessStatus(_ pasteboard: NSPasteboard) -> ClipboardReadAccessStatus {
        guard pasteboard.name == .general else { return .init(policy: .notRequired) }
        guard #available(macOS 15.4, *) else { return .init(policy: .unavailableOnOS) }
        return self.readAccessStatus(pasteboardName: pasteboard.name, accessBehavior: pasteboard.accessBehavior)
    }

    @available(macOS 15.4, *)
    static func readAccessStatus(
        pasteboardName: NSPasteboard.Name,
        accessBehavior: NSPasteboard.AccessBehavior) -> ClipboardReadAccessStatus
    {
        guard pasteboardName == .general else { return .init(policy: .notRequired) }
        let policy: ClipboardReadAccessStatus.Policy = switch accessBehavior {
        case .default: .systemDefault
        case .ask: .ask
        case .alwaysAllow: .alwaysAllow
        case .alwaysDeny: .alwaysDeny
        @unknown default: .unknown
        }
        return .init(policy: policy)
    }

    var literalInsertChangeCount: Int { self.pasteboard.changeCount }

    public func readPlainText() throws -> ClipboardTextContents {
        try Self.requireSilentReadAccess(self.readAccessStatus())
        let generation = self.pasteboard.changeCount
        guard let items = self.pasteboard.pasteboardItems, items.count <= 1 else {
            throw Self.plainTextReadRefusal("Plain-text reads require a complete clipboard with at most one item.")
        }
        var text: String?
        if let item = items.first {
            guard !item.types.isEmpty,
                  !item.types.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("promise") }) else {
                throw Self.plainTextReadRefusal("Clipboard file promises or unavailable representations cannot be read as plain text.")
            }
            if item.types.contains(.string) {
                guard let value = item.string(forType: .string) else {
                    throw Self.plainTextReadRefusal("The advertised plain-text representation could not be read completely.")
                }
                guard value.utf16.count <= 24_000 else {
                    throw Self.plainTextReadRefusal("Clipboard text exceeds the complete 24 KB result limit.")
                }
                text = value
            }
        } else {
            guard let types = self.pasteboard.types, types.isEmpty else {
                throw Self.plainTextReadRefusal("The clipboard item inventory is unavailable.")
            }
        }
        guard self.pasteboard.changeCount == generation else {
            throw Self.plainTextReadRefusal("The clipboard changed during the read; request a fresh read.")
        }
        let result = ClipboardTextContents(present: text != nil, text: text, change_count: generation)
        guard try JSONEncoder().encode(result).count <= 24_000 else {
            throw Self.plainTextReadRefusal("Clipboard text exceeds the complete 24 KB result limit.")
        }
        return result
    }

    /// Reads one clipboard image as a bounded preview; `includingOriginal` also returns the validated source bytes.
    public func readImage(includingOriginal: Bool = false) async throws -> ClipboardImageContents {
        try Self.requireSilentReadAccess(self.readAccessStatus())
        let generation = self.pasteboard.changeCount
        guard let items = self.pasteboard.pasteboardItems, items.count <= 1 else {
            throw PeekabooError.invalidInput("Image reads require a complete clipboard with at most one item.")
        }
        var imageData: Data?
        var imageType: String?
        if let item = items.first {
            guard !item.types.isEmpty,
                  !item.types.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("promise") }) else {
                throw PeekabooError.invalidInput("Clipboard file promises or unavailable representations cannot be read as an image.")
            }
            let supported = [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier]
            if let type = supported.first(where: { item.types.contains(.init($0)) }) {
                guard let data = item.data(forType: .init(type)) else {
                    throw PeekabooError.invalidInput("The advertised image representation could not be read completely.")
                }
                imageData = data
                imageType = type
            } else if item.types.contains(where: { UTType($0.rawValue)?.conforms(to: .image) == true }) {
                throw PeekabooError.invalidInput("Clipboard image reads support PNG, JPEG, or TIFF.")
            }
        } else {
            guard let types = self.pasteboard.types, types.isEmpty else {
                throw PeekabooError.invalidInput("The clipboard item inventory is unavailable.")
            }
        }
        guard self.pasteboard.changeCount == generation else {
            throw PeekabooError.invalidInput("The clipboard changed during the read; request a fresh read.")
        }
        guard let imageData, let imageType else {
            return ClipboardImageContents(present: false, change_count: generation, source: nil, image: nil)
        }
        // Image decoding stays off the GUI actor; only its immutable copy leaves the pasteboard owner.
        let rendering = Task.detached(priority: .userInitiated) {
            try ClipboardImageRenderer.render(imageData, uti: imageType, generation: generation)
        }
        var result = try await withTaskCancellationHandler {
            try await rendering.value
        } onCancel: {
            rendering.cancel()
        }
        try Task.checkCancellation()
        guard self.pasteboard.changeCount == generation else {
            throw PeekabooError.invalidInput("The clipboard changed during the read; request a fresh read.")
        }
        if includingOriginal { result.original = imageData }
        return result
    }

    public func readFiles() throws -> ClipboardFilesContents {
        try Self.requireSilentReadAccess(self.readAccessStatus())
        let generation = self.pasteboard.changeCount
        guard let items = self.pasteboard.pasteboardItems, items.count <= 32 else {
            throw PeekabooError.invalidInput("File reads require a complete clipboard with at most 32 items.")
        }
        var files: [ClipboardFilesContents.File] = []
        for item in items {
            guard !item.types.isEmpty,
                  !item.types.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("promise") }) else {
                throw PeekabooError.invalidInput("Clipboard file promises or unavailable representations cannot be read as file references.")
            }
            guard item.types.contains(.fileURL) else {
                guard !item.types.contains(where: { $0.rawValue == "NSFilenamesPboardType" }) else {
                    throw PeekabooError.invalidInput("Legacy filename lists are unsupported; copy advertised file URL items.")
                }
                continue
            }
            guard let data = item.data(forType: .fileURL), data.count <= 24_000,
                  let raw = String(data: data, encoding: .utf8) else {
                throw PeekabooError.invalidInput("The advertised file URL could not be read completely within 24 KB.")
            }
            guard let url = URL(string: raw, encodingInvalidCharacters: false), url.isFileURL,
                  !(url as NSURL).isFileReferenceURL(),
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil else {
                throw PeekabooError.invalidInput("Clipboard files require ordinary absolute local file URLs.")
            }
            let path = url.path(percentEncoded: false)
            guard path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw PeekabooError.invalidInput("Clipboard files require ordinary absolute local file URLs.")
            }
            files.append(.init(url: raw, path: path))
        }
        guard files.isEmpty || files.count == items.count else {
            throw PeekabooError.invalidInput("Clipboard file reads do not omit mixed non-file items.")
        }
        if items.isEmpty {
            guard let types = self.pasteboard.types, types.isEmpty else {
                throw PeekabooError.invalidInput("The clipboard item inventory is unavailable.")
            }
        }
        guard self.pasteboard.changeCount == generation else {
            throw PeekabooError.invalidInput("The clipboard changed during the read; request a fresh read.")
        }
        let result = ClipboardFilesContents(present: !files.isEmpty, files: files.isEmpty ? nil : files,
                                            change_count: generation)
        guard try JSONEncoder().encode(result).count <= 24_000 else {
            throw PeekabooError.invalidInput("Clipboard file references exceed the complete 24 KB result limit.")
        }
        return result
    }

    private static func plainTextReadRefusal(_ message: String) -> PeekabooError {
        .invalidInput(message)
    }

    public func prepareTemporaryWrite() throws -> any ClipboardTemporaryWriteTransaction {
        try self.prepareTemporaryWrite(maximumBytes: Int.max, maximumItems: Int.max, maximumRepresentations: Int.max)
    }

    public func prepareTemporaryWrite(
        maximumBytes: Int, maximumItems: Int, maximumRepresentations: Int) throws -> any ClipboardTemporaryWriteTransaction
    {
        try Self.requireSilentReadAccess(self.readAccessStatus())
        let originalChangeCount = self.pasteboard.changeCount
        let items = try self.temporarySnapshotItems(
            maximumBytes: maximumBytes, maximumItems: maximumItems, maximumRepresentations: maximumRepresentations)
        guard self.pasteboard.changeCount == originalChangeCount else {
            throw ClipboardTemporaryWriteError.snapshotChanged
        }
        return OwnedClipboardTemporaryWriteTransaction(
            priorClipboardPresent: !items.isEmpty,
            originalChangeCount: originalChangeCount,
            isGeneralPasteboard: self.pasteboard.name == .general,
            access: ClipboardTemporaryWriteAccess(
                changeCount: { self.pasteboard.changeCount },
                write: { request, expectedChangeCount, didClaim in
                    var didDispatch = false
                    return try self.set(
                        request,
                        didDispatch: &didDispatch,
                        expectedChangeCount: expectedChangeCount,
                        didClaim: didClaim)
                },
                restore: { expectedChangeCount in
                    try self.restoreTemporaryItems(
                        items,
                        expectedChangeCount: expectedChangeCount)
                }))
    }

    /// A claimed write that keeps no copy of the prior clipboard, so it never reads it and has nothing to restore.
    public func prepareReplacingWrite() -> any ClipboardTemporaryWriteTransaction {
        OwnedClipboardTemporaryWriteTransaction(
            priorClipboardPresent: false,
            originalChangeCount: self.pasteboard.changeCount,
            isGeneralPasteboard: self.pasteboard.name == .general,
            access: ClipboardTemporaryWriteAccess(
                changeCount: { self.pasteboard.changeCount },
                write: { request, expectedChangeCount, didClaim in
                    var didDispatch = false
                    return try self.set(
                        request,
                        didDispatch: &didDispatch,
                        expectedChangeCount: expectedChangeCount,
                        didClaim: didClaim)
                },
                restore: { _ in
                    throw ClipboardServiceError.writeFailed("A replacing write keeps no prior clipboard to restore")
                }))
    }

    static func requireSilentReadAccess(_ access: ClipboardReadAccessStatus) throws {
        guard access.readAdmitted else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .permissionDenied,
                message: "Programmatic clipboard reads require silently allowed access.",
                hint: "No clipboard contents were read. Check clipboard status and arrange permission outside " +
                    "automation. The manual CLI --allow-prompt option requires intentional human consent.")
        }
    }

    private func temporarySnapshotItems(
        maximumBytes: Int, maximumItems: Int, maximumRepresentations: Int) throws -> [[ClipboardRepresentation]]
    {
        guard let items = self.pasteboard.pasteboardItems else {
            throw ClipboardTemporaryWriteError.snapshotUnavailable
        }
        guard !items.isEmpty else {
            guard let types = self.pasteboard.types, types.isEmpty else {
                throw ClipboardTemporaryWriteError.snapshotUnavailable
            }
            return []
        }
        guard items.count <= maximumItems else { throw ClipboardTemporaryWriteError.snapshotUnavailable }
        var bytes = 0
        var representations = 0
        return try items.map { item in
            guard !item.types.isEmpty else {
                throw ClipboardTemporaryWriteError.snapshotUnavailable
            }
            representations += item.types.count
            guard representations <= maximumRepresentations else { throw ClipboardTemporaryWriteError.snapshotUnavailable }
            return try item.types.map { type in
                guard !type.rawValue.localizedCaseInsensitiveContains("promise") else {
                    throw ClipboardTemporaryWriteError.snapshotUnavailable
                }
                guard let data = item.data(forType: type) else {
                    throw ClipboardTemporaryWriteError.snapshotUnavailable
                }
                guard data.count <= maximumBytes - bytes else { throw ClipboardTemporaryWriteError.snapshotUnavailable }
                bytes += data.count
                return ClipboardRepresentation(utiIdentifier: type.rawValue, data: data)
            }
        }
    }

    private func restoreTemporaryItems(
        _ snapshot: [[ClipboardRepresentation]],
        expectedChangeCount: Int) throws -> ClipboardReadResult?
    {
        let items = try snapshot.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.utiIdentifier))
                else {
                    throw ClipboardServiceError.writeFailed("Unable to prepare a prior clipboard representation")
                }
            }
            return item
        }
        try self.requireTemporaryOwnership(expectedChangeCount)
        let restoredChangeCount = self.pasteboard.clearContents()
        try self.requireTemporaryOwnership(restoredChangeCount)
        guard !items.isEmpty else { return nil }
        guard self.pasteboard.writeObjects(items) else {
            try self.requireTemporaryOwnership(restoredChangeCount)
            throw ClipboardServiceError.writeFailed("Unable to restore the prior clipboard items")
        }
        try self.requireTemporaryOwnership(restoredChangeCount)
        return Self.writeResult(for: ClipboardWriteRequest(representations: snapshot[0]))
    }

    private func requireTemporaryOwnership(_ expectedChangeCount: Int?) throws {
        if let expectedChangeCount, self.pasteboard.changeCount != expectedChangeCount {
            throw ClipboardTemporaryWriteError.ownershipChanged
        }
    }

    // MARK: - Slot storage (cross-process)

    private func slotPasteboardName(for slot: String) -> NSPasteboard.Name {
        let sanitizedSlot = slot
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { scalar -> String in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                return allowed.contains(scalar) ? String(Character(scalar)) : "_"
            }
            .joined()

        return NSPasteboard.Name("\(self.pasteboard.name.rawValue).boo.peekaboo.clipboard.slot.\(sanitizedSlot)")
    }

    // MARK: - Public API

    public func get(prefer uti: UTType?) throws -> ClipboardReadResult? {
        try self.get(prefer: uti, allowPrompt: false)
    }

    public func get(prefer uti: UTType?, allowPrompt: Bool) throws -> ClipboardReadResult? {
        if !allowPrompt {
            try Self.requireSilentReadAccess(self.readAccessStatus())
        }
        guard let types = self.pasteboard.types, !types.isEmpty else { return nil }

        let targetType: NSPasteboard.PasteboardType = if let uti,
                                                         let preferred = types
                                                             .first(where: { $0.rawValue == uti.identifier })
        {
            preferred
        } else if let stringType = types.first(where: { $0 == .string || $0 == .init("public.utf8-plain-text") }) {
            stringType
        } else {
            types[0]
        }

        let data: Data?
        var textPreview: String?

        if targetType == .string, let string = self.pasteboard.string(forType: .string) {
            let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
                of: "\r",
                with: "\n")
            data = normalized.data(using: .utf8)
            textPreview = Self.makePreview(normalized)
        } else {
            data = self.pasteboard.data(forType: targetType)
            if let data, let string = String(data: data, encoding: .utf8) {
                textPreview = Self.makePreview(string)
            }
        }

        guard let data else { return nil }

        return ClipboardReadResult(
            utiIdentifier: targetType.rawValue,
            data: data,
            textPreview: textPreview)
    }

    public func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        var didDispatch = false
        return try self.set(request, didDispatch: &didDispatch)
    }

    public func setActionResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult> {
        try ClipboardMutationResultOwner.perform(
            operation: "Clipboard set",
            mutation: { didDispatch in
                try self.set(request, didDispatch: &didDispatch)
            },
            verify: { _ in self.matches(request: request) })
    }

    public func setFilesActionResult(_ input: ClipboardFilesInput) throws -> DesktopActionResult<Int> {
        var generation: Int?
        return try ClipboardMutationResultOwner.perform(
            operation: "Clipboard files write",
            mutation: { didDispatch in
                let items = try input.files.map { file in
                    let item = NSPasteboardItem()
                    guard item.setData(Data(file.url.utf8), forType: .fileURL) else {
                        throw ClipboardServiceError.writeFailed("Unable to prepare a file reference")
                    }
                    return item
                }
                try Task.checkCancellation()
                let claimed = self.pasteboard.clearContents()
                didDispatch = true
                generation = claimed
                try self.requireTemporaryOwnership(claimed)
                guard self.pasteboard.writeObjects(items) else {
                    throw ClipboardServiceError.writeFailed("Unable to publish all file reference items")
                }
                try self.requireTemporaryOwnership(claimed)
                return input.files.count
            },
            verify: { _ in
                guard let generation, self.readAccessStatus().readAdmitted,
                      self.pasteboard.changeCount == generation,
                      let items = self.pasteboard.pasteboardItems,
                      items.count == input.files.count else { return false }
                for (item, file) in zip(items, input.files) {
                    guard item.types.contains(.fileURL),
                          item.data(forType: .fileURL) == Data(file.url.utf8) else { return false }
                }
                return self.pasteboard.changeCount == generation
            })
    }

    private func set(
        _ request: ClipboardWriteRequest,
        didDispatch: inout Bool,
        expectedChangeCount: Int? = nil,
        didClaim: (Int) -> Void = { _ in }) throws -> ClipboardReadResult
    {
        if !request.fileURLs.isEmpty {
            return try self.setFileItems(
                request.fileURLs, didDispatch: &didDispatch, expectedChangeCount: expectedChangeCount, didClaim: didClaim)
        }
        guard !request.representations.isEmpty else {
            throw ClipboardServiceError.writeFailed("No representations provided.")
        }

        let totalSize = request.representations.reduce(0) { $0 + $1.data.count } +
            (request.alsoText?.utf8.count ?? 0)
        if !request.allowLarge, totalSize > self.sizeLimit {
            throw ClipboardServiceError.sizeExceeded(current: totalSize, limit: self.sizeLimit)
        }

        var types = request.representations.map { NSPasteboard.PasteboardType($0.utiIdentifier) }
        let includesTextType = request.representations.contains(where: Self.isPlainTextRepresentation)
        if request.alsoText != nil || includesTextType {
            if !types.contains(.string) {
                types.append(.string)
            }
        }
        try self.requireTemporaryOwnership(expectedChangeCount)
        let declaredChangeCount = self.pasteboard.declareTypes(types, owner: nil)
        didDispatch = true
        didClaim(declaredChangeCount)
        let ownedChangeCount = expectedChangeCount == nil ? nil : declaredChangeCount

        for representation in request.representations {
            try self.requireTemporaryOwnership(ownedChangeCount)
            let pbType = NSPasteboard.PasteboardType(representation.utiIdentifier)
            guard self.pasteboard.setData(representation.data, forType: pbType) else {
                try self.requireTemporaryOwnership(ownedChangeCount)
                throw ClipboardServiceError.writeFailed("Unable to set type \(representation.utiIdentifier)")
            }
        }

        try self.requireTemporaryOwnership(ownedChangeCount)
        if let alsoText = request.alsoText {
            let written = self.pasteboard.setString(alsoText, forType: .string)
            if ownedChangeCount != nil, !written {
                try self.requireTemporaryOwnership(ownedChangeCount)
                throw ClipboardServiceError.writeFailed("Unable to set the text companion")
            }
        } else if let representation = request.representations.first(where: Self.isPlainTextRepresentation),
                  let fallbackText = String(data: representation.data, encoding: .utf8)
        {
            let written = self.pasteboard.setString(fallbackText, forType: .string)
            if ownedChangeCount != nil, !written {
                try self.requireTemporaryOwnership(ownedChangeCount)
                throw ClipboardServiceError.writeFailed("Unable to set the plain-text companion")
            }
        }
        try self.requireTemporaryOwnership(ownedChangeCount)

        return Self.writeResult(for: request)
    }

    private func setFileItems(
        _ urls: [String],
        didDispatch: inout Bool,
        expectedChangeCount: Int?,
        didClaim: (Int) -> Void) throws -> ClipboardReadResult
    {
        let items = try urls.map { url in
            let item = NSPasteboardItem()
            guard item.setData(Data(url.utf8), forType: .fileURL) else {
                throw ClipboardServiceError.writeFailed("Unable to prepare a file reference")
            }
            return item
        }
        try self.requireTemporaryOwnership(expectedChangeCount)
        let claimed = self.pasteboard.clearContents()
        didDispatch = true
        didClaim(claimed)
        let ownedChangeCount = expectedChangeCount == nil ? nil : claimed
        guard self.pasteboard.writeObjects(items) else {
            try self.requireTemporaryOwnership(ownedChangeCount)
            throw ClipboardServiceError.writeFailed("Unable to publish all file reference items")
        }
        try self.requireTemporaryOwnership(ownedChangeCount)
        return ClipboardReadResult(
            utiIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data(urls[0].utf8), textPreview: nil)
    }

    private static func writeResult(for request: ClipboardWriteRequest) -> ClipboardReadResult {
        let primary = request.representations.first!
        let preview: String? = if let text = request.alsoText {
            Self.makePreview(text)
        } else if Self.isPlainTextRepresentation(primary),
                  let string = String(data: primary.data, encoding: .utf8)
        {
            Self.makePreview(string)
        } else {
            nil
        }

        return ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: preview)
    }

    public func clear() {
        self.pasteboard.clearContents()
    }

    public func clearActionResult() throws -> DesktopActionResult<Void> {
        try ClipboardMutationResultOwner.perform(
            operation: "Clipboard clear",
            mutation: { didDispatch in
                self.pasteboard.clearContents()
                didDispatch = true
            },
            verify: { _ in self.readAccessStatus().readAdmitted && self.pasteboard.types?.isEmpty != false })
    }

    public func save(slot: String) throws {
        try self.save(slot: slot, allowPrompt: false)
    }

    public func save(slot: String, allowPrompt: Bool) throws {
        let trimmedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlot.isEmpty else {
            throw ClipboardServiceError.writeFailed("Slot name must not be empty.")
        }

        let reps = try self.snapshotRepresentations(from: self.pasteboard, allowPrompt: allowPrompt)
        self.slots[trimmedSlot] = reps

        let slotPasteboard = NSPasteboard(name: self.slotPasteboardName(for: trimmedSlot))
        slotPasteboard.clearContents()
        let types = reps.map { NSPasteboard.PasteboardType($0.utiIdentifier) }
        slotPasteboard.declareTypes(types, owner: nil)

        for rep in reps {
            let pbType = NSPasteboard.PasteboardType(rep.utiIdentifier)
            guard slotPasteboard.setData(rep.data, forType: pbType) else {
                throw ClipboardServiceError
                    .writeFailed("Unable to save type \(rep.utiIdentifier) to slot \(trimmedSlot)")
            }
        }
    }

    public func restore(slot: String) throws -> ClipboardReadResult {
        var didDispatch = false
        var restoredRepresentations: [ClipboardRepresentation] = []
        return try self.restore(
            slot: slot,
            didDispatch: &didDispatch,
            restoredRepresentations: &restoredRepresentations)
    }

    public func restoreActionResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult> {
        var restoredRepresentations: [ClipboardRepresentation] = []
        return try ClipboardMutationResultOwner.perform(
            operation: "Clipboard restore",
            mutation: { didDispatch in
                try self.restore(
                    slot: slot,
                    didDispatch: &didDispatch,
                    restoredRepresentations: &restoredRepresentations)
            },
            verify: { _ in self.matches(representations: restoredRepresentations, alsoText: nil) })
    }

    private func restore(
        slot: String,
        didDispatch: inout Bool,
        restoredRepresentations: inout [ClipboardRepresentation]) throws -> ClipboardReadResult
    {
        let trimmedSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSlot.isEmpty else {
            throw ClipboardServiceError.slotNotFound(slot)
        }

        let slotPasteboardName = self.slotPasteboardName(for: trimmedSlot)
        let reps: [ClipboardRepresentation]
        if let cached = self.slots[trimmedSlot], !cached.isEmpty {
            reps = cached
        } else {
            let slotPasteboard = NSPasteboard(name: slotPasteboardName)
            let loaded = try self.snapshotRepresentations(from: slotPasteboard)
            guard !loaded.isEmpty else {
                throw ClipboardServiceError.slotNotFound(trimmedSlot)
            }
            reps = loaded
        }
        restoredRepresentations = reps

        let request = ClipboardWriteRequest(representations: reps)
        let result = try self.set(request, didDispatch: &didDispatch)
        self.slots.removeValue(forKey: trimmedSlot)
        NSPasteboard(name: slotPasteboardName).clearContents()
        return result
    }

    // MARK: - Helpers

    private func snapshotRepresentations(
        from pasteboard: NSPasteboard,
        allowPrompt: Bool = false) throws -> [ClipboardRepresentation]
    {
        if !allowPrompt {
            try Self.requireSilentReadAccess(self.readAccessStatusReader(pasteboard))
        }
        var reps: [ClipboardRepresentation] = []

        if let items = pasteboard.pasteboardItems {
            for item in items {
                for type in item.types {
                    if let data = item.data(forType: type) {
                        reps.append(ClipboardRepresentation(utiIdentifier: type.rawValue, data: data))
                    }
                }
            }
        }

        if !reps.isEmpty {
            return reps
        }

        guard let types = pasteboard.types else { return [] }
        for type in types {
            if let data = pasteboard.data(forType: type) {
                reps.append(ClipboardRepresentation(utiIdentifier: type.rawValue, data: data))
            }
        }

        return reps
    }

    private static func isPlainTextRepresentation(_ representation: ClipboardRepresentation) -> Bool {
        representation.utiIdentifier == UTType.plainText.identifier ||
            representation.utiIdentifier == UTType.utf8PlainText.identifier
    }

    private func matches(request: ClipboardWriteRequest) -> Bool {
        self.matches(representations: request.representations, alsoText: request.alsoText)
    }

    private func matches(representations: [ClipboardRepresentation], alsoText: String?) -> Bool {
        // A completed write is still dispatched when optional readback would require a prompt.
        guard self.readAccessStatus().readAdmitted else { return false }
        for representation in representations {
            let type = NSPasteboard.PasteboardType(representation.utiIdentifier)
            guard let actual = self.pasteboard.data(forType: type),
                  Self.normalizedData(actual, for: representation.utiIdentifier) ==
                  Self.normalizedData(representation.data, for: representation.utiIdentifier)
            else {
                return false
            }
        }
        if let alsoText {
            guard let actual = self.pasteboard.string(forType: .string),
                  Self.normalizedText(actual) == Self.normalizedText(alsoText)
            else {
                return false
            }
        }
        return true
    }

    private static func normalizedData(_ data: Data, for utiIdentifier: String) -> Data {
        guard [UTType.plainText.identifier, UTType.utf8PlainText.identifier].contains(utiIdentifier),
              let text = String(data: data, encoding: .utf8)
        else {
            return data
        }
        return Data(self.normalizedText(text).utf8)
    }

    private static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func makePreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let max = 80
        guard trimmed.count > max else { return trimmed }
        let head = trimmed.prefix(max)
        return "\(head)…"
    }
}
