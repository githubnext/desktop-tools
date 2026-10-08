# desktop-tools

Native macOS desktop inspection and input for agents. It contains:

- A Swift runtime that a signed GUI app embeds. It serves a patched [Peekaboo](https://github.com/openclaw/Peekaboo) Bridge, and the app holds the macOS permissions.
- A signed client CLI that talks to that runtime over a Unix socket.
- A TypeScript client and a runtime-neutral protocol for Node or Bun hosts.

This code was extracted from [Ace](https://github.com/githubnext/ace2), where it backs the `desktop_*` agent tools. Ace remains its first consumer. The proposal is tracked in [ace2#188](https://github.com/githubnext/ace2/issues/188).

The native runtime and client require macOS 15 or later. The `protocol` export and the JavaScript modules install and import on any platform; only native operations need macOS.

## Layout

| Path | Contents |
| --- | --- |
| `native/Package.swift` | `DesktopTools` (dynamic library) and `desktop-tools-client` (executable), with Peekaboo pinned at 4.8.0 |
| `native/sources/runtime` | Embedded Bridge runtime and its C ABI |
| `native/sources/client` | The client CLI: one process per operation, JSON on stdout |
| `native/sources/identity` | Code-signing identity checks and the protocol capability |
| `native/patches` | The ordered Peekaboo patch stack and its [rationale](native/patches/README.md) |
| `src/protocol.ts` | Request/result types, constants, and guards (no imports) |
| `src/client.ts` | Node client with explicit client and socket paths |
| `src/build.ts` | `desktop-tools-build`: reproducible patched native build |
| `dist/` | Compiled JavaScript, checked in so Git installs need no build step |

## Install and build

The package isn't published to a registry. Install it from Git at a pinned commit:

```sh
npm install github:githubnext/desktop-tools#<commit>
```

`dist/` is checked in, so installing runs no build step. Native builds need macOS with Xcode's SDK and Swift 6.2 or later, Git, and Node 22 or later. Ace, Electrobun, and Bun are not required.

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

`--out` receives `libDesktopTools.dylib`, `desktop-tools-client`, and `Licenses/<dependency>/` notices for this package and every resolved pin. Existing files in `<out>/Licenses` are kept.

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

macOS grants Accessibility, Screen Recording, and event synthesis to the embedding app. Each embedding app needs its own grants on each machine. Clients must be signed by the host's team with the exact allowlisted identifier, and the client verifies the host's team. A vendor-signed companion that serves other consumers is not part of this package.

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

## Protocol and semantics

The patches add Bridge operations without changing Peekaboo's protocol version, so the runtime advertises the host capability `dev.githubnext.desktop-tools.protocol.1`. This is a compatibility epoch, not a release number. The client checks it in the handshake and refuses before sending any request (`DESKTOP_PROTOCOL_MISMATCH`). Only use a client with a host built from the same epoch.

Observations publish single-use snapshots bound to an exact process generation, window, and controls. Every dispatched action consumes its snapshot, and stale targets are refused before input. Snapshots live in the host process, so restarting the host invalidates them.

Outcomes:

- `refused`: nothing was sent.
- `unknown`: input may have been delivered. Neither the client nor the runtime retries.
- `completed`: the native operation returned. Its evidence can still mean accepted delivery with an unverified effect, so inspect again before acting on it.

Cancelling a call or reaching its 30-second deadline is not a kill. The client may throw an `AbortError` or return `unknown`, and never reports a safe refusal once input may have started. The native lane stays held until the operation settles.

A killed caller receives nothing. Recording interrupted intent durably and never replaying it is the consumer's job. Ace does this with pi's tool history; this package keeps no journal.

Peekaboo coordinates native work across processes through two shared per-user locations:

- `~/.peekaboo`: operation lanes and mutation watermarks.
- `~/Library/Application Support/Peekaboo/clipboard-paste-transaction.lock`: the clipboard paste gate and its pending-paste reservation, which survives a host restart.

Every embedder on a machine shares these. Do not relocate them per consumer.

## Licenses

This package is MIT licensed. Native builds link:

- Peekaboo, AXorcist: MIT.
- swift-log: Apache-2.0. Ship its NOTICE.
- swift-algorithms, swift-numerics: Apache-2.0 with the Runtime Library Exception.

Commander is resolved but not linked; its MIT license is still copied. `desktop-tools-build` copies each license and notice into `<out>/Licenses`.

## Status

Ace's signed desktop builds shipped these patches, pins, and client before extraction. Since then, the extraction added the protocol capability and the C ABI names.

With a signed reference host and a plain Node consumer of the packed package, these are verified:

- The standalone build.
- Handshake and application inventory.
- Clipboard read.
- Refusal of an invalid snapshot.
- Handshake refusal of a wrong client identifier and of an ad-hoc signature.
- Pre-dispatch `refused` against a host without the protocol capability.

Live input, staleness, restart, and cancellation checks are pending.
