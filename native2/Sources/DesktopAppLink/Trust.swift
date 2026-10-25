import Darwin
import DesktopPeer
import Foundation

/// The reverse of the host's check on its client: a client signed with a team sends nothing to a host that isn't
/// the same user's process signed by that team, so a process that took over the socket path can't read the agent's
/// requests or answer them. An unsigned client, as `swift build` makes for development and tests, trusts any host,
/// as the host checks its client only when it is signed itself.
public enum HostTrust {
	/// The code a refused host gets.
	public static let code = "HOST_UNTRUSTED"

	/// Why the host connected on `fd` isn't trusted, or nil when it is.
	public static func refusal(_ fd: Int32, socket: String) -> String? {
		guard let own = ownSigning() else { return nil }
		guard let peer = try? Peer(socket: fd) else {
			return "The process serving \(socket) couldn't be identified, so nothing was sent to it."
		}
		guard peer.userID == geteuid() else {
			return "The process serving \(socket) (pid \(peer.pid)) runs as another user, so nothing was sent to it. "
				+ "Ask the user to quit it and reopen the desktop host app."
		}
		guard peer.signed(byTeam: own.team) else {
			return "The process serving \(socket) (pid \(peer.pid)) isn't signed by this client's team (\(own.team)), "
				+ "so nothing was sent to it. Ask the user to quit it and reopen the desktop host app."
		}
		return nil
	}
}
