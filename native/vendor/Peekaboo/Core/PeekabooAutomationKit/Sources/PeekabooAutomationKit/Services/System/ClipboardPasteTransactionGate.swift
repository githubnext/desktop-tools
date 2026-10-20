import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

/// A Cmd+V request crossed the point where the receiver may have consumed it,
/// but Peekaboo cannot truthfully claim a verified paste result.
public struct ClipboardPasteOutcomeError: LocalizedError, Sendable {
    public enum Kind: String, Sendable {
        case indeterminate
        case unverified
    }

    public let kind: Kind
    public let causeDescription: String?
    public let clipboardRestoreAttempted: Bool
    public let clipboardRestoreErrorDescription: String?
    public let targetProcessIdentifier: pid_t?
    public let clipboardCleanupStatus: ClipboardTemporaryCleanupStatus?

    public init(
        kind: Kind,
        causeDescription: String? = nil,
        clipboardRestoreAttempted: Bool,
        clipboardRestoreErrorDescription: String? = nil,
        targetProcessIdentifier: pid_t? = nil,
        clipboardCleanupStatus: ClipboardTemporaryCleanupStatus? = nil)
    {
        self.kind = kind
        self.causeDescription = causeDescription
        self.clipboardRestoreAttempted = clipboardRestoreAttempted
        self.clipboardRestoreErrorDescription = clipboardRestoreErrorDescription
        self.targetProcessIdentifier = targetProcessIdentifier
        self.clipboardCleanupStatus = clipboardCleanupStatus
    }

    public var clipboardRestoreSucceeded: Bool? {
        if self.clipboardRestoreErrorDescription != nil {
            return false
        }
        switch self.clipboardCleanupStatus {
        case .restored: return true
        case .preservedNewerContents: return false
        case .notNeeded: return nil
        case nil: return self.clipboardRestoreAttempted ? true : nil
        }
    }

    public var errorDescription: String? {
        let headline = switch self.kind {
        case .indeterminate:
            "Paste outcome is indeterminate: Cmd+V may have pasted; do not retry this paste."
        case .unverified:
            "Background paste delivery could not be verified: Cmd+V may have pasted; do not retry this paste."
        }
        let cause = self.causeDescription.map { " Delivery detail: \($0)" } ?? ""
        let restoration = if let clipboardRestoreErrorDescription {
            " Clipboard restoration failed: \(clipboardRestoreErrorDescription)"
        } else if self.clipboardCleanupStatus == .preservedNewerContents {
            " A newer clipboard update was preserved; the prior contents were not restored."
        } else if self.clipboardCleanupStatus == .notNeeded {
            " The clipboard was not changed by this transaction."
        } else if self.clipboardRestoreAttempted {
            " The prior clipboard state was restored before the transaction lock was released."
        } else {
            " The clipboard was not changed by this transaction."
        }
        return headline + cause + restoration + " Observe the target before taking another action."
    }
}

/// Prevents clipboard-backed paste operations in independent clients from observing
/// or overwriting another client's temporary pasteboard payload.
public enum ClipboardPasteTransactionGate {
    static let lockName = "clipboard-paste-transaction"

    enum GateError: LocalizedError, Sendable {
        case fileSystem(operation: String, path: String, message: String)
        case systemCall(operation: String, path: String, code: Int32)
        case unsafeDirectory(path: String)
        case unsafeLockFile(path: String)
        case lockTimeout(path: String)
        case invalidReservation(path: String)
        case transactionUnavailable

        var errorDescription: String? {
            switch self {
            case let .fileSystem(operation, path, message):
                return "Clipboard paste transaction lock failed during \(operation) at \(path): \(message)"
            case let .systemCall(operation, path, code):
                let message = String(cString: strerror(code))
                return "Clipboard paste transaction lock failed during \(operation) at \(path): \(message)"
            case let .unsafeDirectory(path):
                return "Clipboard paste transaction lock directory is unsafe: \(path)"
            case let .unsafeLockFile(path):
                return "Clipboard paste transaction lock is not a regular file owned by the current user: \(path)"
            case let .lockTimeout(path):
                return "Timed out waiting for the exclusive clipboard paste transaction lock at \(path)."
            case let .invalidReservation(path):
                return "Clipboard paste reservation at \(path) is unreadable or unsupported. No new clipboard mutation was admitted; recover it only after the original receiver has terminated."
            case .transactionUnavailable:
                return "Clipboard paste reservation requires the active transaction gate."
            }
        }
    }

    /// Matches the exclusive ScreenCaptureKit and desktop-mutation flock waits.
    static let maximumLockWait: Duration = .seconds(15)

    /// Serializes callers in a shared host before they enter the file-lock wait loop.
    @MainActor private static var isActive = false
    @TaskLocal private static var transaction: Transaction?
    @MainActor private static var pendingProof: PendingProof?

    private struct Reservation: Codable, Sendable {
        let version: Int
        let id: UUID
        let pid: Int32
        let processStartIdentity: UInt64
        let windowID: Int
    }

    private struct PendingProof: Sendable {
        let id: UUID
        let path: String
        let canRelease: @MainActor @Sendable () async -> Bool
    }

    @MainActor
    private final class Transaction {
        let descriptor: Int32
        let path: String
        var active = true
        var reservation: Reservation?

        init(descriptor: Int32, path: String) {
            self.descriptor = descriptor; self.path = path
        }

        func read() throws -> Reservation? {
            var info = stat()
            guard fstat(self.descriptor, &info) == 0 else { throw self.failure("inspect reservation") }
            if info.st_size == 0 { return nil }
            guard info.st_size > 0, info.st_size <= 2048 else { throw GateError.invalidReservation(path: self.path) }
            var data = Data(count: Int(info.st_size))
            let count = data.withUnsafeMutableBytes { pread(self.descriptor, $0.baseAddress!, $0.count, 0) }
            guard count == data.count,
                  let value = try? JSONDecoder().decode(Reservation.self, from: data),
                  value.version == 1, value.pid > 0, value.processStartIdentity > 0, value.windowID > 0
            else { throw GateError.invalidReservation(path: self.path) }
            return value
        }

        func write(_ value: Reservation?) throws {
            let data = try value.map { try JSONEncoder().encode($0) } ?? Data()
            guard ftruncate(self.descriptor, 0) == 0 else { throw self.failure("truncate reservation") }
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes {
                    pwrite(self.descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset))
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw self.failure("write reservation") }
                offset += written
            }
            guard fsync(self.descriptor) == 0 else { throw self.failure("sync reservation") }
            self.reservation = value
        }

        private func failure(_ operation: String) -> GateError {
            .systemCall(operation: operation, path: self.path, code: errno)
        }
    }

    /// Called synchronously immediately before primary paste-key delivery, never after it.
    /// The deferred proof is bounded and read-only; it must not retain the prior clipboard backup.
    @MainActor
    public static func reservePaste(
        process: ApplicationProcessIdentity, windowID: Int,
        canRelease: @escaping @MainActor @Sendable () async -> Bool) throws -> UUID
    {
        guard let transaction, transaction.active, transaction.reservation == nil else {
            throw GateError.transactionUnavailable
        }
        let value = Reservation(version: 1, id: UUID(), pid: process.processIdentifier,
                                processStartIdentity: process.processStartIdentity, windowID: windowID)
        // A failed metadata write cannot be followed by V delivery. Preserve uncertain disk state on cleanup failure.
        transaction.reservation = value
        do { try transaction.write(value) }
        catch {
            try? transaction.write(nil)
            throw error
        }
        self.pendingProof = PendingProof(id: value.id, path: transaction.path, canRelease: canRelease)
        return value.id
    }

    @MainActor
    public static func releasePaste(_ id: UUID) throws {
        guard let transaction, transaction.active, transaction.reservation?.id == id else {
            throw GateError.transactionUnavailable
        }
        try transaction.write(nil)
        if self.pendingProof?.id == id { self.pendingProof = nil }
    }

    @MainActor
    public static var hasUnresolvedPaste: Bool { self.transaction?.reservation != nil }

    @MainActor
    private static func admit(_ transaction: Transaction) async throws {
        transaction.reservation = try transaction.read()
        guard let reservation = transaction.reservation else {
            if self.pendingProof?.path == transaction.path { self.pendingProof = nil }
            return
        }
        var resolved = self.processGenerationTerminated(reservation) || self.receiverWindowClosed(reservation)
        if !resolved, let proof = self.pendingProof,
           proof.path == transaction.path, proof.id == reservation.id
        {
            resolved = await proof.canRelease()
        }
        if resolved {
            try self.releasePaste(reservation.id)
            return
        }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "A previous clipboard paste to process \(reservation.pid), window \(reservation.windowID) remains unresolved.",
            hint: "No new clipboard mutation was sent. Inspect the original receiver; its observed consumption, closing that window, or the original process quitting resolves ownership.")
    }

    /// A closed receiver window can no longer consume the pending paste, so it resolves ownership like
    /// process termination does. An unavailable window list proves nothing.
    private static func receiverWindowClosed(_ reservation: Reservation) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(reservation.windowID))
        return self.windowClosed(pid: reservation.pid, windowInfo: info as? [[String: Any]])
    }

    static func windowClosed(pid: Int32, windowInfo: [[String: Any]]?) -> Bool {
        guard let windowInfo else { return false }
        guard let owner = windowInfo.first?[kCGWindowOwnerPID as String] as? Int else { return true }
        return owner != Int(pid)
    }

    private static func processGenerationTerminated(_ reservation: Reservation) -> Bool {
        switch SystemIdentityResolver.processStartIdentityObservation(reservation.pid) {
        case let .identity(current): current != reservation.processStartIdentity
        case .absent: true
        case .permissionDenied, .unavailable: false
        }
    }

    @MainActor
    public static func withExclusiveTransaction<T: Sendable>(
        _ operation: () async throws -> T) async throws -> T
    {
        try await self.withExclusiveTransaction(lockPath: self.defaultLockPath, operation: operation)
    }

    @MainActor
    static func withExclusiveTransaction<T: Sendable>(
        lockPath: String,
        lockWait: Duration = Self.maximumLockWait,
        now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        retrySleep: @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(10)) },
        operation: () async throws -> T) async throws -> T
    {
        let deadline = now().advanced(by: lockWait)
        try Task.checkCancellation()
        while self.isActive {
            try self.checkLockDeadline(deadline, now: now(), path: lockPath)
            try await retrySleep()
        }
        try self.checkLockDeadline(deadline, now: now(), path: lockPath)
        self.isActive = true
        defer { self.isActive = false }

        let standardizedLockPath = URL(fileURLWithPath: lockPath).standardizedFileURL.path
        try self.prepareLockDirectory(for: standardizedLockPath)

        let fd = open(
            standardizedLockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw GateError.systemCall(operation: "open", path: standardizedLockPath, code: errno)
        }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else {
            throw GateError.systemCall(operation: "inspect", path: standardizedLockPath, code: errno)
        }
        guard fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_uid == geteuid()
        else {
            throw GateError.unsafeLockFile(path: standardizedLockPath)
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw GateError.systemCall(operation: "secure", path: standardizedLockPath, code: errno)
        }

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw GateError.systemCall(operation: "flock", path: standardizedLockPath, code: errno)
            }

            try self.checkLockDeadline(deadline, now: now(), path: standardizedLockPath)
            try await retrySleep()
        }
        defer { flock(fd, LOCK_UN) }

        try self.checkLockDeadline(deadline, now: now(), path: standardizedLockPath)
        let transaction = Transaction(descriptor: fd, path: standardizedLockPath)
        defer { transaction.active = false }
        return try await Self.$transaction.withValue(transaction) {
            do { try await self.admit(transaction) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as DesktopActionFailure { throw failure }
            catch {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Shared clipboard ownership could not be verified before this operation.",
                    hint: error.localizedDescription)
            }
            try Task.checkCancellation()
            return try await operation()
        }
    }

    @MainActor
    private static func checkLockDeadline(
        _ deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant,
        path: String) throws
    {
        try Task.checkCancellation()
        guard now < deadline else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: GateError.lockTimeout(path: path).localizedDescription,
                standardErrorCode: .timeout)
        }
    }

    static var defaultLockPath: String {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("Peekaboo", isDirectory: true)
            .appendingPathComponent("\(self.lockName).lock", isDirectory: false)
            .standardizedFileURL.path
    }

    private static func prepareLockDirectory(for lockPath: String) throws {
        let directory = URL(fileURLWithPath: lockPath).deletingLastPathComponent().standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
        } catch {
            throw GateError.fileSystem(
                operation: "prepare",
                path: directory.path,
                message: error.localizedDescription)
        }

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else {
            throw GateError.systemCall(operation: "inspect", path: directory.path, code: errno)
        }
        let writableByAnotherUser = directoryInfo.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
        guard directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              !writableByAnotherUser
        else {
            throw GateError.unsafeDirectory(path: directory.path)
        }
    }

    /// Compatibility entry point for callers that predate `SystemIdentityResolver`.
    public static func processStartIdentity(_ processIdentifier: pid_t) -> UInt64? {
        SystemIdentityResolver.processStartIdentity(processIdentifier)
    }

    /// Matches Press delay/hold so a huge restore delay cannot hold the exclusive paste lock unbounded.
    public static let maximumRestoreDelayMilliseconds = 10000

    public static func cappedRestoreDelayMilliseconds(_ milliseconds: Int) -> Int {
        min(max(0, milliseconds), self.maximumRestoreDelayMilliseconds)
    }

    static func pasteConsumptionSleepDuration(milliseconds: Int) -> Duration? {
        let capped = self.cappedRestoreDelayMilliseconds(milliseconds)
        guard capped > 0 else { return nil }
        return .milliseconds(capped)
    }

    /// Waits for Cmd+V consumption, capped at ``maximumRestoreDelayMilliseconds``.
    /// Detached so cancellation cannot restore the previous clipboard before the receiver reads it.
    public static func waitForPasteConsumption(milliseconds: Int) async {
        guard let delay = self.pasteConsumptionSleepDuration(milliseconds: milliseconds) else { return }
        let settle = Task.detached {
            try? await Task.sleep(for: delay)
        }
        await settle.value
    }
}
