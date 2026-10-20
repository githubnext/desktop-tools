import AppKit
import Darwin

/// One read of a process's start time, which tells two processes with the same PID apart.
enum StartIdentity: Equatable {
	case identity(UInt64)
	case absent
	case permissionDenied
	case unavailable

	var value: UInt64? { if case let .identity(g) = self { g } else { nil } }
}

/// The start time in microseconds, as Peekaboo's `SystemIdentityResolver.processStartIdentity` reads it.
func startIdentity(_ pid: pid_t) -> StartIdentity {
	guard pid > 0 else { return .unavailable }
	var info = proc_bsdinfo()
	let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
	let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
	guard read == size else {
		guard read <= 0 else { return .unavailable }
		switch errno {
		case EPERM: return .permissionDenied
		case ESRCH: return .absent
		default: return .unavailable
		}
	}
	let identity = UInt64(info.pbi_start_tvsec).multipliedReportingOverflow(by: 1_000_000).partialValue &+ UInt64(info.pbi_start_tvusec)
	return identity > 0 ? .identity(identity) : .unavailable
}

/// Another user's background-only process, which the inventory skips without a warning when it can't read it.
func foreignProhibited(_ pid: pid_t) -> Bool {
	var info = proc_bsdshortinfo()
	let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
	guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_pid == UInt32(pid),
	      info.pbsi_uid != geteuid(),
	      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
	else { return false }
	return app.activationPolicy == .prohibited
}
