import AppKit

/// Questions only the user may answer, such as whether a caller may control this Mac, shown one at a time.
/// Agents can't answer them: while one is on screen the runtime refuses agent input with SELF_TARGET_REFUSED.
/// Each is a floating window, never an application-modal alert, which would stop the main actor serving agents.
@MainActor
final class Confirmations: NSObject {
	static let shared = Confirmations()

	struct Request: Sendable {
		/// A second request with the key of one that is queued or showing gets the same answer instead of a prompt.
		let key: String
		let title: String
		let message: String
		/// The button that agrees, such as "Allow". Return never presses it, so a keystroke meant for another app
		/// can't agree by accident.
		let allow: String
		/// The button that refuses, also pressed by Escape.
		let deny: String
	}

	enum Answer: Sendable {
		case allow
		case deny
	}

	private struct Pending {
		let request: Request
		var waiters: [CheckedContinuation<Answer?, Never>]
	}

	private var queue: [Pending] = []
	private var showing: Pending?
	private var alert: NSAlert?

	/// The user's answer, or nil when the request was cancelled before it was shown.
	func ask(_ request: Request) async -> Answer? {
		await withCheckedContinuation { continuation in
			if showing?.request.key == request.key {
				showing!.waiters.append(continuation)
			} else if let index = queue.firstIndex(where: { $0.request.key == request.key }) {
				queue[index].waiters.append(continuation)
			} else {
				queue.append(Pending(request: request, waiters: [continuation]))
				showNext()
			}
		}
	}

	/// Drops a queued request, such as one the user already answered from the menu; its askers get nil.
	func cancel(key: String) {
		guard let index = queue.firstIndex(where: { $0.request.key == key }) else { return }
		for waiter in queue.remove(at: index).waiters { waiter.resume(returning: nil) }
	}

	private func showNext() {
		guard showing == nil, !queue.isEmpty else { return }
		showing = queue.removeFirst()
		// Run the modal from the main queue, not from inside the asker's call.
		DispatchQueue.main.async {
			MainActor.assumeIsolated { self.present() }
		}
	}

	private func present() {
		guard let current = showing else { return }
		let alert = NSAlert()
		alert.messageText = current.request.title
		alert.informativeText = current.request.message
		let allow = alert.addButton(withTitle: current.request.allow)
		allow.keyEquivalent = ""
		allow.target = self
		allow.action = #selector(allowed)
		let deny = alert.addButton(withTitle: current.request.deny)
		deny.keyEquivalent = "\u{1b}"
		deny.target = self
		deny.action = #selector(denied)
		alert.layout()
		alert.window.level = .modalPanel
		alert.window.center()
		self.alert = alert
		NSApp.activate()
		alert.window.makeKeyAndOrderFront(nil)
	}

	@objc private func allowed() {
		answer(.allow)
	}

	@objc private func denied() {
		answer(.deny)
	}

	private func answer(_ answer: Answer) {
		alert?.window.orderOut(nil)
		alert = nil
		let waiters = showing?.waiters ?? []
		showing = nil
		for waiter in waiters { waiter.resume(returning: answer) }
		showNext()
	}
}
