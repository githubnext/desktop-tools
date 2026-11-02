// The menu bar app's updater, without its menu: finding a newer release, and fetching, checking and installing it.
// native/sources/callers/updates.swift is a copy, so native/'s build of the same app compiles.
import Darwin
import Foundation
import Security

/// A release version such as 0.18.0 or 0.19.0-beta.1, compared part by part; a prerelease sorts before its release.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
	public let numbers: [Int]
	public let prerelease: String?
	/// As written, without a leading v: what release assets are named with.
	public let description: String

	public init?(_ text: String) {
		let text = text.hasPrefix("v") ? String(text.dropFirst()) : text
		let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		let fields = parts[0].split(separator: ".", omittingEmptySubsequences: false)
		guard (1...4).contains(fields.count),
			fields.allSatisfy({ !$0.isEmpty && $0.count < 10 && $0.allSatisfy { $0.isASCII && $0.isNumber } })
		else { return nil }
		numbers = fields.map { Int($0)! }
		if parts.count == 2 {
			guard !parts[1].isEmpty else { return nil }
			prerelease = String(parts[1])
		} else {
			prerelease = nil
		}
		description = text
	}

	public static func == (a: AppVersion, b: AppVersion) -> Bool {
		!(a < b) && !(b < a)
	}

	public static func < (a: AppVersion, b: AppVersion) -> Bool {
		for index in 0..<max(a.numbers.count, b.numbers.count) {
			let x = index < a.numbers.count ? a.numbers[index] : 0
			let y = index < b.numbers.count ? b.numbers[index] : 0
			if x != y { return x < y }
		}
		switch (a.prerelease, b.prerelease) {
		case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
		case (.some, nil): return true
		default: return false
		}
	}
}

/// One release as GitHub's REST API lists it.
public struct Release: Decodable, Sendable {
	public struct Asset: Decodable, Sendable {
		public let name: String
		public let url: String
		public let size: Int

		public init(name: String, url: String, size: Int) {
			self.name = name
			self.url = url
			self.size = size
		}

		enum CodingKeys: String, CodingKey {
			case name, size
			case url = "browser_download_url"
		}
	}

	public let tag: String
	public let draft: Bool
	public let prerelease: Bool
	public let page: String?
	public let assets: [Asset]

	public init(tag: String, draft: Bool = false, prerelease: Bool = false, page: String? = nil, assets: [Asset]) {
		self.tag = tag
		self.draft = draft
		self.prerelease = prerelease
		self.page = page
		self.assets = assets
	}

	enum CodingKeys: String, CodingKey {
		case draft, prerelease, assets
		case tag = "tag_name"
		case page = "html_url"
	}
}

/// A release newer than the running app, and the disk image to install it from.
public struct Update: Sendable, Equatable {
	public let version: AppVersion
	public let dmg: URL
	public let size: Int
	/// The release's page, where the user can download it by hand.
	public let page: URL?
}

public struct UpdateError: LocalizedError, Sendable {
	public let message: String
	public init(_ message: String) { self.message = message }
	public var errorDescription: String? { message }
}

public enum Updates {
	/// The team that signs and notarizes Desktop Tools releases; nothing else is ever installed.
	public static let team = "8S43JJMN6B"
	/// The release app's bundle ID. The development app (`.dev`) and other builds never update themselves.
	public static let identifier = "dev.githubnext.desktop-tools"
	/// The repository is public, so its releases are listed without signing in. Unauthenticated calls get 60 an hour
	/// per address; the app makes one a day, and one each time the user asks.
	public static let feed = URL(string: "https://api.github.com/repos/githubnext/desktop-tools/releases?per_page=20")!

	/// What scripts/release.ts names the disk image for `version`.
	public static func assetName(_ version: AppVersion) -> String {
		"desktop-tools-\(version)-macos-arm64.dmg"
	}

	/// The newest published, non-prerelease release above `current` that carries its disk image, or nil.
	public static func select(_ releases: [Release], newerThan current: AppVersion) -> Update? {
		releases.compactMap { release -> Update? in
			guard !release.draft, !release.prerelease, let version = AppVersion(release.tag), version.prerelease == nil,
				current < version,
				let asset = release.assets.first(where: { $0.name == assetName(version) }),
				let url = URL(string: asset.url), url.scheme == "https" || url.scheme == "file"
			else { return nil }
			return Update(version: version, dmg: url, size: asset.size, page: release.page.flatMap(URL.init(string:)))
		}.max { $0.version < $1.version }
	}

	/// What a release's code must satisfy: Developer ID signed by `team`, notarized, with this identifier when given.
	/// The installed app's macOS permissions are tied to its identifier and team, so a build that satisfies this keeps
	/// them.
	public static func requirement(team: String, identifier: String?) -> String {
		(identifier.map { "identifier \"\($0)\" and " } ?? "")
			+ "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
			// Developer ID: the intermediate is Apple's Developer ID CA, the leaf a Developer ID Application certificate.
			+ " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
			+ " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
			+ " and notarized"
	}

	/// Validates the code at `path`, all of it, against each requirement. Throws what failed.
	public static func verify(_ path: URL, requirements: [String]) throws {
		var code: SecStaticCode?
		guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else {
			throw UpdateError("\(path.lastPathComponent) isn't signed code")
		}
		for text in requirements {
			var requirement: SecRequirement?
			guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
				throw UpdateError("Invalid code requirement: \(text)")
			}
			let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
			var error: Unmanaged<CFError>?
			let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
			guard status == errSecSuccess else {
				let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
					?? (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
				throw UpdateError("\(path.lastPathComponent) isn't a notarized Desktop Tools release signed by team \(Updates.team): \(reason)")
			}
		}
	}

	/// The running process's team and designated requirement, when its signature is valid.
	public static func ownSigning() -> (team: String?, designated: String)? {
		var running: SecCode?
		guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
			SecCodeCheckValidity(running, [], nil) == errSecSuccess
		else { return nil }
		var code: SecStaticCode?
		var requirement: SecRequirement?
		var text: CFString?
		var info: CFDictionary?
		guard SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
			SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
			SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text,
			SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
		else { return nil }
		let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
		return (team, text as String)
	}
}

/// Finds, fetches and installs updates for the app at `installed`. Every step runs off the main thread.
public struct Installer: Sendable {
	/// The running app's bundle, which an update replaces in place.
	public let installed: URL
	public let current: AppVersion
	public let identifier: String
	public let team: String
	/// The running app's own designated requirement, which macOS keys its permissions to; an update must satisfy it
	/// too. Nil skips it, as tests do.
	public let designated: String?
	/// Gatekeeper's assessment, the same `spctl` check the release script runs; off only in tests of unnotarized code.
	public let assess: Bool

	public init(installed: URL, current: AppVersion, identifier: String = Updates.identifier, team: String = Updates.team,
		designated: String?, assess: Bool = true)
	{
		self.installed = installed
		self.current = current
		self.identifier = identifier
		self.team = team
		self.designated = designated
		self.assess = assess
	}

	/// The newest release above the running version, or nil when the app is up to date.
	public func check(_ feed: URL) async throws -> Update? {
		var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		request.setValue("Desktop Tools/\(current)", forHTTPHeaderField: "User-Agent")
		let (data, response) = try await URLSession.shared.data(for: request)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
			throw UpdateError("GitHub answered \(http.statusCode)\(message.map { ": \($0)" } ?? "")")
		}
		guard let releases = try? JSONDecoder().decode([Release].self, from: data) else {
			throw UpdateError("The release list from \(feed.host ?? feed.path) couldn't be read")
		}
		return Updates.select(releases, newerThan: current)
	}

	/// A folder on the installed app's volume, so the finished update can be swapped in with one rename.
	public func stagingFolder() throws -> URL {
		try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
	}

	/// Downloads `update`'s disk image, checks its signature, copies the app out of it, and checks the app. Returns
	/// the app, ready for `replace`; it is in its own staging folder, which the caller removes if it isn't installed.
	public func prepare(_ update: Update) async throws -> URL {
		let folder = try stagingFolder()
		do {
			let dmg = folder.appendingPathComponent(update.dmg.lastPathComponent)
			let (downloaded, response) = try await URLSession.shared.download(from: update.dmg)
			if let http = response as? HTTPURLResponse, http.statusCode != 200 {
				try? FileManager.default.removeItem(at: downloaded)
				throw UpdateError("Downloading \(update.dmg.lastPathComponent) failed with HTTP \(http.statusCode)")
			}
			try FileManager.default.moveItem(at: downloaded, to: dmg)
			let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? -1
			guard update.size <= 0 || size == update.size else {
				throw UpdateError("\(dmg.lastPathComponent) is \(size) bytes, not the \(update.size) the release lists")
			}
			// The disk image is signed and notarized as well; nothing is mounted unless it checks out.
			try Updates.verify(dmg, requirements: [Updates.requirement(team: team, identifier: nil)])
			if assess {
				try run("/usr/sbin/spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", dmg.path])
			}
			let mount = folder.appendingPathComponent("mount")
			try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
			try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
			let app = folder.appendingPathComponent(installed.lastPathComponent)
			do {
				try run("/usr/bin/ditto", [mount.appendingPathComponent("Desktop Tools.app").path, app.path])
			} catch {
				_ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
				throw error
			}
			_ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
			try? FileManager.default.removeItem(at: dmg)
			try verify(app, version: update.version)
			return app
		} catch {
			try? FileManager.default.removeItem(at: folder)
			throw error
		}
	}

	/// Checks a prepared app: its whole signature, Gatekeeper's assessment, its bundle ID, and that it is `version`.
	public func verify(_ app: URL, version: AppVersion) throws {
		try Updates.verify(app, requirements: [Updates.requirement(team: team, identifier: identifier)] + (designated.map { [$0] } ?? []))
		if assess { try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) }
		let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
		guard info["CFBundleIdentifier"] as? String == identifier else {
			throw UpdateError("The update's bundle ID is \(info["CFBundleIdentifier"] ?? "missing"), not \(identifier)")
		}
		guard let found = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), found == version,
			current < found
		else {
			throw UpdateError("The update says it is version \(info["CFBundleShortVersionString"] ?? "?"), not \(version)")
		}
	}

	/// Checks `app` again, then swaps it with the installed app in one rename and removes the old one. The installed
	/// path never names a half-copied app.
	public func replace(with app: URL, version: AppVersion) throws {
		try verify(app, version: version)
		guard renamex_np(app.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
			let reason = String(cString: strerror(errno))
			throw UpdateError("Desktop Tools can't replace itself at \(installed.path): \(reason)")
		}
		// The old app is now where the update was.
		try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
	}

	@discardableResult
	private func run(_ tool: String, _ arguments: [String]) throws -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: tool)
		process.arguments = arguments
		let output = Pipe()
		process.standardOutput = output
		process.standardError = output
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		guard process.terminationStatus == 0 else {
			throw UpdateError("\((tool as NSString).lastPathComponent) \(arguments.first ?? "") failed: \(text)")
		}
		return text
	}
}
