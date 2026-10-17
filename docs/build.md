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
2. Checks Peekaboo's pinned revision.
3. Assembles the ordered patch stack in a private Git index and applies only the missing suffix. Drift from every complete prefix fails the build instead of producing unexpected source.
4. Builds in release mode.

`--out` receives `libDesktopTools.dylib`, `desktop-tools-client`, `desktop-tools-app` (the [Desktop Tools app](app.md) host), and `Licenses/<dependency>/` notices for this package and every resolved pin. Existing files in `<out>/Licenses` are kept.

Give each concurrent build its own `--scratch` directory, or run builds one at a time. Patches are applied to the scratch's Peekaboo checkout outside SwiftPM's lock. The default scratch is `native/.build` inside the package, which is not suitable for an installed dependency.

Peekaboo's own tests take the real desktop operation locks in `~/.peekaboo` (`global.lock` and its turnstile) whenever a test uses the default coordination root. The path comes from the account database, so changing `HOME` doesn't isolate it. A hung or slow test run blocks every desktop operation for the same user, including the installed Desktop Tools app. A timed-out operation names the processes holding the lock open. Run Peekaboo tests with a narrow `--filter` and a time limit, and stop any run that hangs.

The build does not sign or stage the Swift runtime. Embedding apps own both. If an app's deployment target needs bundled Swift libraries, stage them with `xcrun swift-stdlib-tool --copy` into `Contents/Frameworks`; binaries carry an `@loader_path/../Frameworks` rpath for that.

CI checks that `dist/` matches a fresh compile and that the modules import on Linux. It also builds the native artifacts, unsigned, on macOS with Xcode 26.2.
