import DesktopProtocol
import Foundation
import Security

// Copied from swift-spike's Inspect.swift so this lane builds alone; delete this file when merging into swift-spike.

/// An element ID from an earlier accessibility snapshot of the same window.
struct ScopeRequest: Sendable {
	let snapshot: String
	let element: String
}

extension Tools {
	static func scopeArgument(_ value: JSON) throws -> ScopeRequest {
		guard let keys = value.keys, keys.count == 2,
		      let snapshot = value["snapshot"]?.string, let element = value["element"]?.string,
		      [snapshot, element].allSatisfy({ !$0.isEmpty && $0.utf16.count <= 256 && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil })
		else { throw ToolError("Choose scope as the snapshot_id and an element ID from an earlier desktop_inspect of this window.") }
		return ScopeRequest(snapshot: snapshot, element: element)
	}
}

// The part of swift-spike's Hooks that desktop_fill_password calls, with a stand-in for the runtime's PasswordFill
// (which reads the Keychain and asks the app to confirm text) so this lane can fill without libDesktopTools.
// swift-spike's own Hooks.swift and DesktopTools/Password.swift replace all of it.
enum Hooks {
	nonisolated(unsafe) static var secureTextFill: (@Sendable (SecureTextFillContext) async -> SecureTextFillAuthorization)? = { context in
		switch context.secret {
		case let .keychain(item):
			if item.kind == .internet, context.webHost != item.name.lowercased() {
				return .refuse(context.webHost.map {
					"The Keychain item is for \(item.name), but the field is on \($0). Nothing was typed."
				} ?? "A Keychain internet password fills only a field in a web page on its server. Nothing was typed.")
			}
			return await readKeychain(item)
		case .text:
			// Only the app can ask the user to confirm a password the agent supplied.
			return .refuse("Nobody answered the request to fill the password in time. Nothing was typed.")
		}
	}

	static let noSecureTextFill = "This host does not fill secure text fields."

	struct KeychainItem: Sendable, Equatable {
		enum Kind: String, Sendable {
			case generic, internet
		}

		let kind: Kind
		let name: String
		let account: String?
	}

	struct SecureTextFillContext: Sendable {
		enum Secret: Sendable {
			case keychain(KeychainItem)
			case text(String)
		}

		let client: pid_t
		let targetProcess: pid_t
		let applicationName: String?
		let bundleIdentifier: String?
		let webHost: String?
		let secret: Secret
	}

	enum SecureTextFillAuthorization: Sendable {
		case fill(String)
		case refuse(String)
	}

	struct Call: Sendable {
		let client: pid_t
	}

	@TaskLocal static var call: Call?

	private static func readKeychain(_ item: KeychainItem) async -> SecureTextFillAuthorization {
		var query: [String: Any] = [
			kSecClass as String: item.kind == .internet ? kSecClassInternetPassword : kSecClassGenericPassword,
			(item.kind == .internet ? kSecAttrServer : kSecAttrService) as String: item.name,
			kSecMatchLimit as String: kSecMatchLimitAll,
			kSecReturnAttributes as String: true,
		]
		if let account = item.account { query[kSecAttrAccount as String] = account }
		let named = "the Keychain item for \(item.name)" + (item.account.map { " and account \($0)" } ?? "")
		var matches: CFTypeRef?
		let found = SecItemCopyMatching(query as CFDictionary, &matches)
		guard found == errSecSuccess, let items = matches as? [[String: Any]], !items.isEmpty else {
			return .refuse(found == errSecItemNotFound
				? "There is no \(named) in the Keychain. Nothing was typed."
				: "Reading \(named) failed (\(found)). Nothing was typed.")
		}
		guard items.count == 1 else { return .refuse("Several Keychain items match \(item.name); name the account too. Nothing was typed.") }
		query[kSecMatchLimit as String] = kSecMatchLimitOne
		query[kSecReturnAttributes as String] = nil
		query[kSecReturnData as String] = true
		nonisolated(unsafe) let request = query as CFDictionary
		let (status, data): (OSStatus, Data?) = await withCheckedContinuation { continuation in
			Thread.detachNewThread {
				var data: CFTypeRef?
				let status = SecItemCopyMatching(request, &data)
				continuation.resume(returning: (status, data as? Data))
			}
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
