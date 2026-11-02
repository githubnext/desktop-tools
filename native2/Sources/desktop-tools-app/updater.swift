import AppKit
#if canImport(DesktopCore)
import DesktopCore
#else
import DesktopToolsCallers
#endif

/// Keeps the release app up to date from the repository's GitHub Releases: a check at launch and once a day while
/// automatic updates are on, and whenever the user asks. Only notarized builds signed by the release team are
/// installed (see `Installer`). An automatic update installs once agents have been quiet for a while, and every call
/// already running finishes first; the app then relaunches, keeping its permissions.
@MainActor
final class Updater {
	enum Phase {
		case idle
		case checking
		case downloading(AppVersion)
		/// Checked and staged; `app` replaces the installed one on install or quit.
		case ready(Update, app: URL)
		case installing(AppVersion)
	}

	private(set) var phase = Phase.idle
	/// Why the last check or install failed, until the next one succeeds.
	private(set) var failure: String?
	private(set) var lastChecked = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
	var automatic = UserDefaults.standard.object(forKey: "automaticUpdates") as? Bool ?? true {
		didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdates") }
	}

	private let installer: Installer
	private let feed: URL
	private var lastAttempt: Date?
	private var timer: Timer?
	/// Writes a line to the activity log.
	private let log: (String) -> Void
	/// When an agent last operated, if one has since launch; an automatic install waits until this is long past.
	private let lastActivity: () -> Date?
	/// Whether the user is in the middle of something the restart would undo, such as paused input or an open prompt.
	private let busy: () -> Bool
	/// Stops serving and returns once every running call has finished; `resume` serves again if the install fails.
	private let drain: () async -> Void
	private let resume: () -> Void

	/// How long agents must have been quiet before an automatic install restarts the app.
	static let quiet: TimeInterval = 10 * 60
	static let interval: TimeInterval = 24 * 60 * 60

	/// Nil for any build that isn't the release app signed by the release team, such as `Desktop Tools Dev`: those
	/// never update themselves.
	static func make(log: @escaping (String) -> Void, lastActivity: @escaping () -> Date?, busy: @escaping () -> Bool,
		drain: @escaping () async -> Void, resume: @escaping () -> Void) -> Updater?
	{
		let bundle = Bundle.main
		guard bundle.bundleIdentifier == Updates.identifier,
			let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init),
			let own = Updates.ownSigning(), own.team == Updates.team
		else { return nil }
		// DESKTOP_TOOLS_UPDATE_FEED points a test copy at a local release list.
		let override = ProcessInfo.processInfo.environment["DESKTOP_TOOLS_UPDATE_FEED"].flatMap(URL.init(string:))
		let installer = Installer(installed: bundle.bundleURL, current: version, designated: own.designated)
		return Updater(installer: installer, feed: override ?? Updates.feed, log: log, lastActivity: lastActivity,
			busy: busy, drain: drain, resume: resume)
	}

	private init(installer: Installer, feed: URL, log: @escaping (String) -> Void, lastActivity: @escaping () -> Date?,
		busy: @escaping () -> Bool, drain: @escaping () async -> Void, resume: @escaping () -> Void)
	{
		self.installer = installer
		self.feed = feed
		self.log = log
		self.lastActivity = lastActivity
		self.busy = busy
		self.drain = drain
		self.resume = resume
	}

	/// Checks a minute after launch, then every 10 minutes looks whether a day has passed or a staged update can go in.
	func start() {
		Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
			MainActor.assumeIsolated { self.tick() }
		}
		timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { _ in
			MainActor.assumeIsolated { self.tick() }
		}
	}

	private func tick() {
		guard automatic else { return }
		switch phase {
		case .idle:
			// A failed check is tried again an hour later.
			let due = lastChecked.map { Date().timeIntervalSince($0) >= Self.interval } ?? true
			if due, lastAttempt.map({ Date().timeIntervalSince($0) >= 60 * 60 }) ?? true {
				lastAttempt = Date()
				Task { await check(manual: false) }
			}
		case let .ready(update, app):
			let last = lastActivity() ?? .distantPast
			if Date().timeIntervalSince(last) >= Self.quiet, !busy() {
				Task { await install(update, app: app, manual: false) }
			}
		default:
			break
		}
	}

	/// The title of the menu's update item.
	var title: String {
		switch phase {
		case .idle: "Check for Updates…"
		case .checking: "Checking for Updates…"
		case let .downloading(version): "Downloading Desktop Tools \(version)…"
		case let .ready(update, _): "Install Desktop Tools \(update.version) and Relaunch"
		case let .installing(version): "Installing Desktop Tools \(version)…"
		}
	}

	/// What the menu shows under it: when it last checked, or why it failed.
	var detail: String {
		if let failure { return "Update failed: \(failure)" }
		if case .ready = phase {
			return automatic ? "Installs when agents have been idle for 10 minutes, or at quit" : "Installs at quit"
		}
		guard let lastChecked else { return "Version \(installer.current)" }
		let ago = RelativeDateTimeFormatter().localizedString(for: lastChecked, relativeTo: Date())
		return "Version \(installer.current), checked \(ago)"
	}

	var enabled: Bool {
		switch phase {
		case .idle, .ready: true
		default: false
		}
	}

	/// The menu item: checks, or installs what is staged.
	func choose() {
		switch phase {
		case .idle: Task { await check(manual: true) }
		case let .ready(update, app): Task { await install(update, app: app, manual: true) }
		default: break
		}
	}

	/// Looks for a newer release and stages it. A manual check reports what it found, and offers to install at once.
	func check(manual: Bool) async {
		guard case .idle = phase else { return }
		phase = .checking
		let installer = installer
		let feed = feed
		let found: Update?
		do {
			found = try await Task.detached { try await installer.check(feed) }.value
			lastChecked = Date()
			UserDefaults.standard.set(lastChecked, forKey: "lastUpdateCheck")
		} catch {
			return fail(error, manual: manual, doing: "checking for updates")
		}
		guard let update = found else {
			phase = .idle
			failure = nil
			if manual {
				Confirmations.shared.tell("Desktop Tools is up to date",
					"Version \(installer.current) is the newest release.")
			}
			return
		}
		phase = .downloading(update.version)
		log("Downloading Desktop Tools \(update.version)")
		let app: URL
		do {
			app = try await Task.detached { try await installer.prepare(update) }.value
		} catch {
			return fail(error, manual: manual, doing: "downloading Desktop Tools \(update.version)", page: update.page)
		}
		failure = nil
		phase = .ready(update, app: app)
		log("Desktop Tools \(update.version) is downloaded and verified")
		if manual {
			let answer = await Confirmations.shared.ask(.init(
				key: "update \(update.version)",
				title: "Install Desktop Tools \(update.version)?",
				message: """
					Desktop Tools will relaunch. Calls agents are running finish first, and agents reconnect on their \
					next call. Your permissions and approved agents are kept.
					""",
				allow: "Install and Relaunch",
				deny: "Later"))
			if answer == .allow { await install(update, app: app, manual: true) }
		} else {
			tick()
		}
	}

	/// Stops serving once running calls finish, swaps the new app in, and relaunches it. On failure the app keeps
	/// running the old version and serves again.
	func install(_ update: Update, app: URL, manual: Bool) async {
		guard case .ready = phase else { return }
		phase = .installing(update.version)
		log("Installing Desktop Tools \(update.version)")
		await drain()
		let installer = installer
		do {
			try await Task.detached { try installer.replace(with: app, version: update.version) }.value
		} catch {
			resume()
			try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
			return fail(error, manual: manual, doing: "installing Desktop Tools \(update.version)", page: update.page)
		}
		relaunch()
	}

	/// Installs a staged update when the app quits, without relaunching. Returns at once otherwise.
	func installAtQuit() {
		guard case let .ready(update, app) = phase else { return }
		do {
			try installer.replace(with: app, version: update.version)
			log("Installed Desktop Tools \(update.version); it runs next time the app opens")
		} catch {
			log("Couldn't install Desktop Tools \(update.version) at quit: \(error.localizedDescription)")
			try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
		}
	}

	/// Opens the new app through LaunchServices once this process has exited, then quits. A small shell waits for the
	/// exit, since the new app won't start while this one holds the state folder's lock.
	private func relaunch() {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		var open = ["/usr/bin/open", "-n", "-g"]
		// A copy run with its own state folder or feed, as in testing, keeps them.
		for name in ["DESKTOP_TOOLS_STATE", "DESKTOP_TOOLS_UPDATE_FEED"] {
			if let value = ProcessInfo.processInfo.environment[name] { open += ["--env", "\(name)=\(value)"] }
		}
		process.arguments = [
			"-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; shift; exec \"$@\"", "sh",
			"\(getpid())",
		] + open + [installer.installed.path]
		do {
			try process.run()
		} catch {
			log("Couldn't relaunch Desktop Tools: \(error.localizedDescription); open it again to finish updating")
		}
		NSApp.terminate(nil)
	}

	private func fail(_ error: Error, manual: Bool, doing what: String, page: URL? = nil) {
		phase = .idle
		failure = error.localizedDescription
		log("Update failed while \(what): \(error.localizedDescription)")
		guard manual else { return }
		let where_ = page.map { " You can download it from \($0.absoluteString)." } ?? ""
		Confirmations.shared.tell("Desktop Tools couldn't update", "Failed while \(what): \(error.localizedDescription)\(where_)")
	}
}
