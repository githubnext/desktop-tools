# Install and build

The package isn't published to a registry. Install it from Git at a pinned commit:

```sh
npm install github:githubnext/desktop-tools#<commit>
```

`dist/` is checked in, so installing runs no build step. Native builds need macOS with Xcode's SDK and Swift 6.2 or later, Git, and Node 22 or later.

Build the native artifacts with the installed binary, never through a registry lookup:

```sh
npm exec --no -- desktop-tools-build --out <directory> --scratch <directory>
```

From a clone:

```sh
git clone https://github.com/githubnext/desktop-tools && cd desktop-tools
npm ci
npm run build:native          # writes build/, scratch in native/.build
npm run build:js && npm run check   # after editing src/
```

The build:

1. Resolves only the versions in `Package.resolved`.
2. Checks that the runtime's allowed operations survive the embedded host's allowlist.
3. Builds in release mode.

Peekaboo is vendored in `native/vendor/Peekaboo`: version 4.8.0 with our changes, which you edit there like any other source. `git diff peekaboo-upstream-4d43dc9 -- native/vendor/Peekaboo` shows them, and [`native/vendor/README.md`](https://github.com/githubnext/desktop-tools/blob/main/native/vendor/README.md) explains each one.

`--out` receives `libDesktopTools.dylib`, `desktop-tools-client`, `desktop-tools-app` (the [Desktop Tools app](app.md) host), and `Licenses/<dependency>/` notices for this package, Peekaboo and every resolved pin. Existing files in `<out>/Licenses` are kept.

Give each concurrent build its own `--scratch` directory, or run builds one at a time. The default scratch is `native/.build` inside the package, which is not suitable for an installed dependency.

Peekaboo's own tests take the real desktop operation locks in `~/.peekaboo` (`global.lock` and its turnstile) whenever a test uses the default coordination root. The path comes from the account database, so changing `HOME` doesn't isolate it. A hung or slow test run blocks every desktop operation for the same user, including the installed Desktop Tools app. A timed-out operation names the processes holding the lock open. Run Peekaboo tests with a narrow `--filter` and a time limit, and stop any run that hangs.

The build does not sign or stage the Swift runtime. Embedding apps own both. If an app's deployment target needs bundled Swift libraries, stage them with `xcrun swift-stdlib-tool --copy` into `Contents/Frameworks`; binaries carry an `@loader_path/../Frameworks` rpath for that.

CI checks that `dist/` matches a fresh compile and that the modules import on Linux. It also builds the native artifacts, unsigned, on macOS with Xcode 26.2.

## Development app

Test native changes in the real app with:

```sh
npm run dev-app            # build, sign, install and open
npm run dev-app -- --stop  # quit it
```

Every checkout and worktree installs the same `~/Library/Application Support/desktop-tools/dev/Desktop Tools Dev.app`. It has its own bundle identity, `dev.githubnext.desktop-tools.dev`, nested under the release app's, and the name **Desktop Tools Dev**. Building quits the running copy, replaces the bundle in place and opens it again through LaunchServices with `open`. Launching its executable directly can attribute permission checks to the launching terminal or agent instead of the app.

This exists because macOS ties permissions to the app. The Accessibility, Screen Recording and Keyboard input grants belong to a bundle identity and its signing requirement. Screen capture also needs a separate, dated approval to "bypass the system private window picker", which macOS appears to ask for again for each copy of an app that captures, even when the grant is on. Development builds therefore never use the release identity, which would swap the installed app's binaries under its grants, and never run from scattered build folders, each of which would ask again. Grant **Desktop Tools Dev** once in System Settings, and approve its capture prompt once; rebuilds keep both.

The app serves `~/.local/state/desktop-tools-dev/desktop.sock`, the default for the development identity, or `DESKTOP_TOOLS_STATE` when set at build time, which is passed with `open --env`. Point the MCP server or `npm run live-check` at the same folder with `DESKTOP_TOOLS_STATE`. Its approved agents are kept in that folder too, so the development app asks about each agent once, separately from the installed app.

Every build is signed with one identity, so the designated requirement stays the same across rebuilds: `DESKTOP_TOOLS_CODESIGN_IDENTITY` when set, otherwise the repository's Git setting `desktopTools.codesignIdentity`. Set the Git value once per Mac to the SHA-1 of an Apple Development or Developer ID identity from `security find-identity -v -p codesigning`, since several certificates can share a name:

```sh
git config desktopTools.codesignIdentity <SHA-1>
```

It lives in the repository's `.git/config`, which all worktrees share, and is never committed. Ad-hoc signing (`-`) is refused, because it can't keep permissions across builds. Builds use `native/.build` as scratch unless you pass `--scratch <directory>`; give concurrent builds their own. Don't install a development build in `/Applications`.

## Releases

Each change that users would notice adds a bullet under `## [Unreleased]` in [CHANGELOG.md](https://github.com/githubnext/desktop-tools/blob/main/CHANGELOG.md), under Added, Changed or Fixed, with its PR link. To cut a release:

1. In one PR, bump `version` in `package.json` and `package-lock.json`, update the `#v…` tag pinned in `README.md` and `docs/mcp.md`, and rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` above a new, empty `## [Unreleased]`. Update the compare links at the bottom of the file. `npm test` fails if the version has no entries.
2. After it merges, run the release workflow with `publish`: `gh workflow run release.yml -f publish=true`. It publishes `v` plus the version, using that version's CHANGELOG section (`node scripts/changelog.ts`) as the release notes, and stops before building if the section is missing.
