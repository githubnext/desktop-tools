import DesktopAppLink

// What `desktop-client status` and `repair` print, as native/'s client prints it.

struct HostSuccess: Encodable {
	let success = true
	let data: HostReport
}

struct HostFailure: Encodable {
	struct Message: Encodable {
		let code: String
		let message: String
	}

	let success = false
	let error: Message
}
