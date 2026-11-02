import DesktopCore
import Foundation
import Testing

struct UpdatesTests {
	private func version(_ text: String) -> AppVersion {
		AppVersion(text)!
	}

	@Test
	func `versions compare part by part, and a prerelease comes before its release`() {
		#expect(version("0.18.0") < version("0.18.1"))
		#expect(version("0.9.0") < version("0.10.0"))
		#expect(version("0.18") == version("0.18.0"))
		#expect(version("v1.0.0") == version("1.0.0"))
		#expect(version("1.0.0-beta.2") < version("1.0.0-beta.10"))
		#expect(version("1.0.0-beta.10") < version("1.0.0"))
		#expect(!(version("1.0.0") < version("1.0.0")))
		#expect(version("v0.18.0").description == "0.18.0")
		for bad in ["", "v", "1..0", "1.0.0-", "1.x", "+1.0", "1.0.0.0.0", "-1.0", " 1.0"] {
			#expect(AppVersion(bad) == nil, "\(bad)")
		}
	}

	private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, asset: String? = nil,
		url: String? = nil) -> Release
	{
		let name = asset ?? "desktop-tools-\(tag.dropFirst())-macos-arm64.dmg"
		return Release(tag: tag, draft: draft, prerelease: prerelease, page: "https://github.com/x/releases/tag/\(tag)",
			assets: [.init(name: name, url: url ?? "https://github.com/x/releases/download/\(tag)/\(name)", size: 42)])
	}

	@Test
	func `the newest published release above the running one is chosen`() {
		let releases = [
			release("v0.17.0"), release("v0.20.0", draft: true), release("v0.19.0"), release("v0.21.0-beta.1"),
			release("v0.19.5", prerelease: true), release("v0.18.1"),
		]
		let update = Updates.select(releases, newerThan: version("0.18.0"))
		#expect(update?.version == version("0.19.0"))
		#expect(update?.dmg.absoluteString == "https://github.com/x/releases/download/v0.19.0/desktop-tools-0.19.0-macos-arm64.dmg")
		#expect(update?.size == 42)
		#expect(Updates.select(releases, newerThan: version("0.19.0")) == nil)
		#expect(Updates.select([], newerThan: version("0.18.0")) == nil)
	}

	@Test
	func `a release without its disk image, or served over plain http, is skipped`() {
		let releases = [
			release("v0.20.0", asset: "desktop-tools-0.20.0-macos-x64.dmg"),
			release("v0.19.1", url: "http://example.com/desktop-tools-0.19.1-macos-arm64.dmg"),
			release("not-a-version"),
			release("v0.19.0"),
		]
		#expect(Updates.select(releases, newerThan: version("0.18.0"))?.version == version("0.19.0"))
	}

	@Test
	func `GitHub's release list decodes`() throws {
		let json = """
			[{"tag_name":"v0.18.0","draft":false,"prerelease":false,"html_url":"https://github.com/githubnext/desktop-tools/releases/tag/v0.18.0",
			"assets":[{"name":"desktop-tools-0.18.0-macos-arm64.dmg","size":2789765,
			"browser_download_url":"https://github.com/githubnext/desktop-tools/releases/download/v0.18.0/desktop-tools-0.18.0-macos-arm64.dmg"}]}]
			"""
		let releases = try JSONDecoder().decode([Release].self, from: Data(json.utf8))
		let update = Updates.select(releases, newerThan: version("0.17.1"))
		#expect(update?.version == version("0.18.0"))
		#expect(update?.page?.absoluteString == "https://github.com/githubnext/desktop-tools/releases/tag/v0.18.0")
	}

	@Test
	func `the requirement names the team, Developer ID, notarization and the bundle ID`() {
		let app = Updates.requirement(team: "8S43JJMN6B", identifier: "dev.githubnext.desktop-tools")
		#expect(app.hasPrefix("identifier \"dev.githubnext.desktop-tools\" and anchor apple generic"))
		#expect(app.contains("certificate leaf[subject.OU] = \"8S43JJMN6B\""))
		#expect(app.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
		#expect(app.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
		#expect(app.hasSuffix(" and notarized"))
		#expect(!Updates.requirement(team: "8S43JJMN6B", identifier: nil).contains("identifier"))
	}

	@Test
	func `code from anyone else is refused`() throws {
		let requirement = Updates.requirement(team: Updates.team, identifier: Updates.identifier)
		// Apple's own app: valid, but not this team's.
		#expect(throws: UpdateError.self) {
			try Updates.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"), requirements: [requirement])
		}
		// An ad hoc signed copy of an app, with the release's bundle ID.
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("updates-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		let app = folder.appendingPathComponent("Desktop Tools.app")
		let bin = app.appendingPathComponent("Contents/MacOS")
		try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: bin.appendingPathComponent("desktop-tools-app"))
		let plist: [String: Any] = ["CFBundleIdentifier": Updates.identifier, "CFBundleExecutable": "desktop-tools-app",
			"CFBundlePackageType": "APPL", "CFBundleShortVersionString": "99.0.0"]
		try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
			.write(to: app.appendingPathComponent("Contents/Info.plist"))
		let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path])
		sign.waitUntilExit()
		#expect(sign.terminationStatus == 0)
		#expect(throws: UpdateError.self) { try Updates.verify(app, requirements: [requirement]) }
		// Unsigned: nothing at all.
		#expect(throws: UpdateError.self) { try Updates.verify(folder, requirements: [requirement]) }
	}

	@Test
	func `an installed release satisfies the requirement`() throws {
		let installed = URL(fileURLWithPath: "/Applications/Desktop Tools.app")
		try #require(FileManager.default.fileExists(atPath: installed.path), "Install Desktop Tools to run this")
		try Updates.verify(installed, requirements: [Updates.requirement(team: Updates.team, identifier: Updates.identifier)])
		// The same release fails for another bundle ID or team.
		#expect(throws: UpdateError.self) {
			try Updates.verify(installed, requirements: [Updates.requirement(team: Updates.team, identifier: "dev.githubnext.desktop-tools.dev")])
		}
		#expect(throws: UpdateError.self) {
			try Updates.verify(installed, requirements: [Updates.requirement(team: "Q6L2SF6YDW", identifier: Updates.identifier)])
		}
	}

	/// The whole install, from a local release list to the swapped bundle, against a real release disk image named by
	/// DESKTOP_TOOLS_UPDATE_DMG, into a copy of an app in a temporary folder. It needs no network.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["DESKTOP_TOOLS_UPDATE_DMG"] != nil))
	func `a release disk image installs over an older app in place`() async throws {
		let dmg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DESKTOP_TOOLS_UPDATE_DMG"]!)
		let name = dmg.lastPathComponent
		let shipped = try #require(AppVersion(String(name.dropFirst("desktop-tools-".count).dropLast("-macos-arm64.dmg".count))))
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("updates-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		let installed = folder.appendingPathComponent("Desktop Tools.app")
		try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
		try Data("old".utf8).write(to: installed.appendingPathComponent("Contents/old"))
		let size = try FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as! Int
		let feed = folder.appendingPathComponent("releases.json")
		let list = [["tag_name": "v\(shipped)", "draft": false, "prerelease": false,
			"assets": [["name": name, "size": size, "browser_download_url": dmg.absoluteString]]]]
		try JSONSerialization.data(withJSONObject: list).write(to: feed)

		let older = Installer(installed: installed, current: AppVersion("0.1.0")!, designated: nil)
		let update = try #require(try await older.check(feed))
		#expect(update.version == shipped)
		let app = try await older.prepare(update)
		#expect(app.deletingLastPathComponent() != folder)
		try older.replace(with: app, version: update.version)
		#expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/old").path))
		#expect(!FileManager.default.fileExists(atPath: app.deletingLastPathComponent().path))
		try Updates.verify(installed, requirements: [Updates.requirement(team: Updates.team, identifier: Updates.identifier)])

		// The same release is not an update for itself, and a staged app is refused if it isn't the version listed.
		let current = Installer(installed: installed, current: shipped, designated: nil)
		#expect(try await current.check(feed) == nil)
		let wrong = try #require(AppVersion("\(shipped.numbers[0] + 1).0.0"))
		#expect(throws: UpdateError.self) { try older.verify(installed, version: wrong) }
	}
}
