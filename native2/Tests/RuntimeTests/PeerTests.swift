import Darwin
import DesktopAppLink
import DesktopPeer
import Testing

struct PeerTests {
	@Test
	func `a socket peer is checked by its signing team`() throws {
		var fds: [Int32] = [0, 0]
		#expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
		defer { close(fds[0]); close(fds[1]) }
		let peer = try Peer(socket: fds[0])
		#expect(peer.pid == getpid())
		#expect(peer.userID == geteuid())
		// The test runner isn't signed by a team, and a team that would change the requirement's grammar never passes.
		#expect(!peer.signed(byTeam: "ABCDE12345"))
		#expect(!peer.signed(byTeam: "X\" or anchor apple"))
	}

	@Test
	func `an unsigned client trusts any host, as an unsigned host serves any client`() {
		var fds: [Int32] = [0, 0]
		#expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
		defer { close(fds[0]); close(fds[1]) }
		#expect(ownSigning() == nil)
		#expect(HostTrust.refusal(fds[0], socket: "/tmp/test.sock") == nil)
	}
}
