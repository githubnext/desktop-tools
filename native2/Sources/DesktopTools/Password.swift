// Ported from native/Sources/runtime's password.swift: the decision behind Hooks.secureTextFill.
import Darwin
import DesktopHost
import Foundation
import Security

/// Decides each secure text field fill: it reads a named Keychain item, so macOS asks the user for that item, or it
/// asks the user before typing a password the agent supplied. The secret is never logged, returned or kept.
final class PasswordFill: @unchecked Sendable {
	static let shared = PasswordFill()
	/// How long a Keychain prompt or a confirmation may wait for the user before the fill is refused.
	static let answerSeconds: Double = 60
	private let lock = NSLock()
	private var alwaysAllow = false
	private var confirm: (@convention(c) (UInt64, UnsafePointer<CChar>) -> Void)?
	private var withdraw: (@convention(c) (UInt64) -> Void)?
	private var answers: [UInt64: CheckedContinuation<Bool?, Never>] = [:]
	private var nextID: UInt64 = 1

	func setAlwaysAllow(_ value: Bool) {
		lock.lock()
		alwaysAllow = value
		lock.unlock()
	}

	func setConfirmationHandlers(
		ask: (@convention(c) (UInt64, UnsafePointer<CChar>) -> Void)?, cancel: (@convention(c) (UInt64) -> Void)?
	) {
		lock.lock()
		confirm = ask
		withdraw = cancel
		lock.unlock()
	}

	func authorize(_ context: Hooks.SecureTextFillContext) async -> Hooks.SecureTextFillAuthorization {
		switch context.secret {
		case let .keychain(item):
			if item.kind == .internet, context.webHost != item.name.lowercased() {
				return .refuse(context.webHost.map {
					"The Keychain item is for \(item.name), but the field is on \($0). Nothing was typed."
				} ?? "A Keychain internet password fills only a field in a web page on its server. Nothing was typed.")
			}
			return await Self.read(item)
		case let .text(secret):
			if lock.withLock({ alwaysAllow }) { return .fill(secret) }
			switch await ask(context) {
			case true?: return .fill(secret)
			case false?: return .refuse("The user denied filling the password. Nothing was typed.")
			case nil: return .refuse("Nobody answered the request to fill the password in time. Nothing was typed.")
			}
		}
	}

	/// Asks the embedding app to confirm one fill; nil when it can't ask or nobody answered in time.
	private func ask(_ context: Hooks.SecureTextFillContext) async -> Bool? {
		let caller = Callers.shared.resolve(client: context.client)?.caller.name ?? "An agent"
		let app = context.applicationName ?? context.bundleIdentifier ?? "an app"
		let place = context.webHost.map { "\(app), on \($0)" } ?? app
		let request: [String: String] = [
			"key": "password-fill",
			"title": "Allow \(caller) to fill a password?",
			"message": "\(caller) wants to type a password it supplied into a password field in \(place). Desktop Tools never shows or records the password.",
			"allow": "Allow Once",
			"deny": "Deny",
		]
		let json = String(decoding: try! JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
		let next: (UInt64, @convention(c) (UInt64, UnsafePointer<CChar>) -> Void)? = lock.withLock {
			guard let confirm else { return nil }
			defer { nextID += 1 }
			return (nextID, confirm)
		}
		guard let (id, confirm) = next else { return nil }
		let timeout = Task {
			try await Task.sleep(for: .seconds(Self.answerSeconds))
			// Withdraw the unanswered prompt, which also lets agent input through again.
			if self.answer(id, allowed: nil), let withdraw = self.lock.withLock({ self.withdraw }) {
				nonisolated(unsafe) let withdraw = withdraw
				DispatchQueue.main.async { withdraw(id) }
			}
		}
		defer { timeout.cancel() }
		return await withCheckedContinuation { continuation in
			lock.withLock { answers[id] = continuation }
			// A C function pointer captures nothing, so calling it on the main queue is safe.
			nonisolated(unsafe) let confirm = confirm
			DispatchQueue.main.async { json.withCString { confirm(id, $0) } }
		}
	}

	/// Resumes a pending confirmation once; later answers for it are ignored. Returns whether it was pending.
	@discardableResult
	func answer(_ id: UInt64, allowed: Bool?) -> Bool {
		let continuation = lock.withLock { answers.removeValue(forKey: id) }
		continuation?.resume(returning: allowed)
		return continuation != nil
	}

	/// Reads one password item. macOS asks the user unless they already allowed this app for the item, and the
	/// call blocks until they answer, so it runs off the main actor and gives up waiting after `answerSeconds`.
	private static func read(_ item: Hooks.KeychainItem) async -> Hooks.SecureTextFillAuthorization {
		var query: [String: Any] = [
			kSecClass as String: item.kind == .internet ? kSecClassInternetPassword : kSecClassGenericPassword,
			(item.kind == .internet ? kSecAttrServer : kSecAttrService) as String: item.name,
			kSecMatchLimit as String: kSecMatchLimitAll,
			kSecReturnAttributes as String: true,
		]
		if let account = item.account { query[kSecAttrAccount as String] = account }
		let named = "the Keychain item for \(item.name)" + (item.account.map { " and account \($0)" } ?? "")
		// Attributes are read without a prompt; the secret is read only when exactly one item matches.
		var matches: CFTypeRef?
		let found = SecItemCopyMatching(query as CFDictionary, &matches)
		guard found == errSecSuccess, let items = matches as? [[String: Any]], !items.isEmpty else {
			return .refuse(found == errSecItemNotFound
				? "There is no \(named) in the Keychain. Nothing was typed."
				: "Reading \(named) failed (\(found)). Nothing was typed.")
		}
		guard items.count == 1 else {
			return .refuse("Several Keychain items match \(item.name); name the account too. Nothing was typed.")
		}
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		query[kSecReturnAttributes as String] = nil
		query[kSecReturnData as String] = true
		nonisolated(unsafe) let request = query as CFDictionary
		let result: (OSStatus, Data?)? = await withCheckedContinuation { continuation in
			let once = Once(continuation)
			Thread.detachNewThread {
				var data: CFTypeRef?
				let status = SecItemCopyMatching(request, &data)
				once.resume((status, data as? Data))
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + answerSeconds) { once.resume(nil) }
		}
		guard let (status, data) = result else {
			return .refuse("Nobody answered the Keychain prompt for \(named) in time. Nothing was typed.")
		}
		switch status {
		case errSecSuccess:
			guard let data, let secret = String(data: data, encoding: .utf8) else {
				return .refuse("The password in \(named) is not text. Nothing was typed.")
			}
			return .fill(secret)
		case errSecUserCanceled, errSecAuthFailed:
			return .refuse("The user denied access to \(named). Nothing was typed.")
		default:
			return .refuse("Reading \(named) failed (\(status)). Nothing was typed.")
		}
	}
}

/// Resumes a continuation the first time only, from whichever of several threads gets there first.
private final class Once<T: Sendable>: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<T, Never>?

	init(_ continuation: CheckedContinuation<T, Never>) {
		self.continuation = continuation
	}

	func resume(_ value: T) {
		lock.lock()
		let pending = continuation
		continuation = nil
		lock.unlock()
		pending?.resume(returning: value)
	}
}

/// Lets agent-supplied passwords fill without asking each time. Only the embedding app sets it; it starts off.
@_cdecl("desktop_tools_set_password_autofill")
public func setPasswordAutofill(_ enabled: Bool) {
	PasswordFill.shared.setAlwaysAllow(enabled)
}

/// Sets the functions the runtime calls, on the main thread, to ask the user something and to withdraw a question
/// nobody answered in time. `ask` receives an ID and a JSON request with `key`, `title`, `message`, `allow` and
/// `deny`, and the app answers with `desktop_tools_answer_confirmation`. Without them, agent-supplied passwords are
/// refused unless always allowed.
@_cdecl("desktop_tools_set_confirmation_handlers")
public func setConfirmationHandlers(
	_ ask: (@convention(c) (UInt64, UnsafePointer<CChar>) -> Void)?, _ cancel: (@convention(c) (UInt64) -> Void)?
) {
	PasswordFill.shared.setConfirmationHandlers(ask: ask, cancel: cancel)
}

/// Answers one confirmation; an ID that was already answered or timed out is ignored.
@_cdecl("desktop_tools_answer_confirmation")
public func answerConfirmation(_ id: UInt64, _ allowed: Bool) {
	PasswordFill.shared.answer(id, allowed: allowed)
}
