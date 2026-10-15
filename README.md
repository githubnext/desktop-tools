# desktop-tools

Native macOS desktop inspection and input for agents. It contains:

- A Swift runtime that a signed GUI app embeds. It serves a patched [Peekaboo](https://github.com/openclaw/Peekaboo) Bridge, and the app holds the macOS permissions.
- A signed client CLI that talks to that runtime over a Unix socket.
- A TypeScript client and a runtime-neutral protocol for Node or Bun hosts.

The native runtime and client require macOS 15 or later. The `protocol` export and the JavaScript modules install and import on any platform; only native operations need macOS.

## Install and build

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

`--out` receives `libDesktopTools.dylib`, `desktop-tools-client`, `desktop-tools-app` (the standalone host below), and `Licenses/<dependency>/` notices for this package and every resolved pin. Existing files in `<out>/Licenses` are kept.

Give each concurrent build its own `--scratch` directory, or run builds one at a time. Patches are applied to the scratch's Peekaboo checkout outside SwiftPM's lock. The default scratch is `native/.build` inside the package, which is not suitable for an installed dependency.

The build does not sign or stage the Swift runtime. Embedding apps own both. If an app's deployment target needs bundled Swift libraries, stage them with `xcrun swift-stdlib-tool --copy` into `Contents/Frameworks`; binaries carry an `@loader_path/../Frameworks` rpath for that.

CI checks that `dist/` matches a fresh compile and that the modules import on Linux. It also builds the native artifacts, unsigned, on macOS with Xcode 26.2.

## Embed

1. Copy `libDesktopTools.dylib` and `desktop-tools-client` into the app bundle, and ship `Licenses/`.
2. Sign the library, the client, and the app with the same Apple Development or Developer ID team. Sign the client with an exact identifier, for example `codesign --identifier <app-id>.desktop-client`.
3. From the app's GUI process, load the library and call its C ABI:

| Symbol | Meaning |
| --- | --- |
| `void desktop_tools_start(const char *socket, const char *client)` | Serve the Bridge on `socket` for the exact signed `client` identifier from this app's team |
| `char *desktop_tools_status(void)` | JSON `{ state, error?, accessibility, screenRecording, eventSynthesizing, clipboardRead }`; free with `desktop_tools_free` |
| `void desktop_tools_stop(void)` | Drain native operations and stop; poll status until `stopped` |
| `void desktop_tools_permission(const char *kind)` | Request `accessibility`, `screenRecording`, or `eventSynthesizing` |
| `void desktop_tools_free(void *)` | Release a status string |

macOS grants Accessibility, Screen Recording, and event synthesis to the embedding app. Each embedding app needs its own grants on each machine. Clients must be signed by the host's team with the exact allowlisted identifier, and the client verifies the host's team. For agents outside an embedding app, use the Desktop Tools app below.

## Desktop Tools app

`Desktop Tools.app` (`dev.githubnext.desktop-tools`) is a menu bar host for agents that don't embed the library, such as Claude Code or Codex through the MCP server. It holds its own Accessibility, Screen Recording and Keyboard input grants, shown and requested from its menu, and serves `~/.local/state/desktop-tools/desktop.sock`. It links `desktop-client` there to its signed client. Turning off **Serve agents** stops the runtime.

Anything running as the user can use those grants while the app serves, so grant them only on machines where that is acceptable, and quit the app when it isn't needed.

```sh
node dist/app.js --out build --identity "Developer ID Application: … (TEAM)" --release
```

`assemble(out, scratch?)` and `sign(app, identity, release)` in `dist/app.js` are what the release workflow uses.

## Use from Node

```js
import { createDesktop } from "@githubnext/desktop-tools";

const desktop = createDesktop({
	client: "/Applications/Example.app/Contents/MacOS/desktop-tools-client",
	socket: "/path/to/desktop.sock",
	name: "Example",
});
const apps = await desktop({ op: "apps" }, AbortSignal.timeout(30_000));
```

Each result has:

- `text`: bounded JSON written for a model.
- `data`: the same final object, parsed.
- `image`: a base64 JPEG or PNG, when the result has one.
- `outcome`, for actions: `completed`, `refused`, or `unknown`.

Before using an observation or receipt, check its `target_receipt` and the inventory completeness fields. Image bytes appear only in `image`.

## Use from an MCP client

`desktop-tools-mcp` (`dist/mcp.js`) serves the desktop tools over stdio MCP, with Ace's native-first guidance as its instructions. By default it uses Desktop Tools.app's signed client and socket in `~/.local/state/desktop-tools`:

```sh
claude mcp add desktop -- node <path>/dist/mcp.js
```

To use another signed host's grants instead, pass its client, socket, and name. For Ace Canary:

```sh
claude mcp add desktop -- node <path>/dist/mcp.js \
	--client ~/.local/state/ace-canary/desktop-client \
	--socket ~/.local/state/ace-canary/desktop.sock \
	--name "Ace Canary"
```

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.desktop]
command = "node"
args = ["<path>/dist/mcp.js"]
```

The tool names, descriptions, and argument schemas come from `@githubnext/desktop-tools/tools` (`desktopTools`, `desktopRequest`), which Ace's `desktop_*` tools also use.

Action results start with `Outcome: completed`, `refused`, or `unknown`. Actions run one at a time, and `notifications/cancelled` aborts a call; cancellation does not undo input already delivered.

**Warning:** the server acts with the host app's macOS Accessibility, Screen Recording, and clipboard permissions. It asks for no approval per call beyond what the MCP client itself requires, so any session that can call it can read the screen and clipboard and send input to any app.

## Licenses

This package is MIT licensed. Native builds link:

- Peekaboo, AXorcist: MIT.
- swift-log: Apache-2.0. Ship its NOTICE.
- swift-algorithms, swift-numerics: Apache-2.0 with the Runtime Library Exception.

Commander is resolved but not linked; its MIT license is still copied. `desktop-tools-build` copies each license and notice into `<out>/Licenses`.
