import Darwin
import Foundation
import Security

// Ported from Peekaboo's PeekabooBridgeCodeSignatureIdentity (MIT): a socket peer is trusted by the signature of
// the exact process generation its audit token names, so a reused PID or a replaced executable can't pass.

@_silgen_name("csops_audittoken")
private func csops_audittoken(
	_ pid: pid_t, _ operation: UInt32, _ address: UnsafeMutableRawPointer?, _ size: Int,
	_ token: UnsafeMutablePointer<audit_token_t>?
) -> Int32

/// The signature a client must carry: Apple-anchored, from `team`, with exactly `identifier`.
public struct ClientRequirement: Sendable {
	public let team: String
	public let identifier: String

	public init(team: String, identifier: String) {
		self.team = team
		self.identifier = identifier
	}
}

/// The process at the other end of a connected Unix socket.
public struct Peer: Sendable {
	public let pid: pid_t
	private let token: audit_token_t

	public init(socket fd: Int32) throws {
		var token = audit_token_t()
		var size = socklen_t(MemoryLayout<audit_token_t>.size)
		guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { throw POSIXError(.EPROTO) }
		let pid = audit_token_to_pid(token)
		guard size == MemoryLayout<audit_token_t>.size, pid > 0 else { throw POSIXError(.EPROTO) }
		self.pid = pid
		self.token = token
	}

	public var userID: uid_t { audit_token_to_euid(token) }

	/// Whether the peer's running code satisfies `requirement`. The on-disk signature counts only when its code
	/// directory hash is the kernel's for the live process, before and after it is read.
	public func satisfies(_ requirement: ClientRequirement) -> Bool {
		guard Self.safe(requirement.identifier, extra: ".-_"), Self.safe(requirement.team, extra: "") else { return false }
		return meets("identifier \"\(requirement.identifier)\" and anchor apple generic and "
			+ "certificate leaf[subject.OU] = \"\(requirement.team)\"")
	}

	/// Whether the peer's running code is Apple-anchored signed by `team`, with any identifier: how a client checks
	/// its host, since an embedding app hosts under its own identifier.
	public func signed(byTeam team: String) -> Bool {
		guard Self.safe(team, extra: "") else { return false }
		return meets("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
	}

	private func meets(_ text: String) -> Bool {
		guard let before = liveHash() else { return false }
		var tokenData = token
		let data = withUnsafeBytes(of: &tokenData) { Data($0) }
		var code: SecCode?
		var staticCode: SecStaticCode?
		var compiled: SecRequirement?
		var information: CFDictionary?
		guard SecRequirementCreateWithString(text as CFString, [], &compiled) == errSecSuccess, let compiled,
		      SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
		      let code, SecCodeCheckValidity(code, [], compiled) == errSecSuccess,
		      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
		      SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources), compiled) == errSecSuccess,
		      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
		      let values = information as? [String: Any],
		      values[kSecCodeInfoUnique as String] as? Data == before,
		      liveHash() == before
		else { return false }
		return true
	}

	/// The kernel's code directory hash for the token's process generation.
	private func liveHash() -> Data? {
		var token = token
		var hash = [UInt8](repeating: 0, count: 20)
		let result = hash.withUnsafeMutableBytes { csops_audittoken(pid, 5, $0.baseAddress, $0.count, &token) }
		guard result == 0, hash.contains(where: { $0 != 0 }) else { return nil }
		return Data(hash)
	}

	/// Narrow character sets keep the values from changing the requirement's grammar.
	private static func safe(_ value: String, extra: String) -> Bool {
		!value.isEmpty && value.unicodeScalars.allSatisfy {
			($0.isASCII && CharacterSet.alphanumerics.contains($0)) || extra.unicodeScalars.contains($0)
		}
	}
}

/// This process's own signing team and identifier, when it is validly Apple-anchored signed with a team; a client
/// must then come from the same team.
public func ownSigning() -> (team: String, identifier: String)? {
	var code: SecCode?
	var staticCode: SecStaticCode?
	var information: CFDictionary?
	guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
	      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
	      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
	      let values = information as? [String: Any],
	      let identifier = values[kSecCodeInfoIdentifier as String] as? String,
	      let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
	else { return nil }
	var requirement: SecRequirement?
	let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
	guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
	      SecCodeCheckValidity(code, [], requirement) == errSecSuccess
	else { return nil }
	return (team, identifier)
}
