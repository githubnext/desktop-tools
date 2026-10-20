# Swapping over to native2 (#143)

native2 is merged beside the shipped stack, not in place of it. This page lists what still separates the two and the steps that would let native2 replace the Node server, the native client and Peekaboo. The [README](README.md) covers how native2 is built and checked.

## Today: side by side

| | Shipped | native2 |
|---|---|---|
| MCP server | `dist/mcp.js` (Node), set up through `npx` | `desktop-tools-mcp` (Swift, stdio), or `dist/mcp.js --wire 2` |
| Embedders | `createDesktop` | `createDesktop({ wire: 2 })`, with native2's `desktop-tools-client` |
| Per call | Node validates, then runs `desktop-tools-client` once per call | one long-lived socket to the host; `createDesktop({ wire: 2 })` keeps one `desktop-tools-client --serve` holding it |
| Host | `Desktop Tools.app`, loading `libDesktopTools.dylib` (Peekaboo's Bridge) | `desktop-tools-host` from a terminal, or native2's `libDesktopTools.dylib` |
| Socket and state | `~/.local/state/desktop-tools` | `~/.local/state/desktop-tools2`, or `$DESKTOP_TOOLS2_STATE` |
| Wire | Peekaboo Bridge requests | length-prefixed JSON frames (`DesktopProtocol/Wire.swift`) |

They share no socket, state folder or hotkey, and only one lock: Peekaboo's clipboard paste lock in `~/Library/Application Support/Peekaboo`, whose record of a paste still pending keeps either stack from replacing the clipboard under the other's Command-V. native2 takes none of Peekaboo's `~/.peekaboo` locks, and neither the npm package (`files`), CI nor the release builds it. Every parity run so far drove both at once. The macOS grants differ: the standalone host uses the grants of the terminal that runs it, while the app holds its own.

## Issues

### Tools that don't do everything yet

- **desktop_fill_password** fills only inside the dylib, where the app's hook decides. The standalone host refuses.
- **desktop_menubar_items** has no fallback when MenuBarAgent doesn't draw the menu bar.
- **desktop_switch_space** is checked only up to its refusals, on a Mac with one Space.

### Limits both stacks share

Found while porting desktop_dialog_answer's path entry, which now follows Peekaboo's (focus the panel, expand it, set its path field or use Go to Folder, set a Save panel's name, read both back):

- A Save sheet on this macOS has no `PathTextField`, so its folder can't be read back and a path answer ends unknown even when Go to Folder took it. The name is read back.
- A standalone Open panel (TextEdit's File > Open…) is an `AXStandardWindow`, which path entry and button presses don't treat as a dialog, so both refuse it; desktop_dialog still lists it.
- desktop_key refuses a window while a sheet holds its keyboard focus, so a stray sheet such as Go to Folder can only be closed with a foreground desktop_system_key.

### Runtime dylib

- The dev app signs it and the client with the team identity, and its signed peer check holds: the bundled client is served, and an unsigned one is dropped before its hello and refused with HOST_NOT_SERVING. The app's approval prompt and pause haven't been run end to end through it.

### Not yet checked live

- live-check's Safari checks (#79, #82, #86, #88, #92's web grid, #99's web field, #107's read) skip while the user's Safari is open. #90 switches input sources and #120 needs the app's approval prompt.
- Background launch and open ([#162](https://github.com/githubnext/desktop-tools/issues/162)) haven't run live. The check: type continuously in TextEdit while launching an app that isn't running and opening a PDF in Preview, both without `activate`. No keystroke should land elsewhere and TextEdit should stay frontmost; then inspect and click the new windows in the background. It needs the user's go-ahead, since a regression takes their focus.

### Bench on real apps

`node scripts/bench.mjs --runs 20` on 2026-10-20, read-only, comparing the shipped stack (`node dist/mcp.js` with the installed app) against native2's MCP server bundled in the dev app. Times are p50 / p95 in milliseconds. Safari was left out because the user's own windows were open.

| | Shipped | native2 |
|---|---|---|
| startup | 110 | 20 |
| desktop_apps | 171 / 179 | 29 / 40 |
| desktop_apps query | 169 / 178 | 22 / 24 |
| desktop_windows | 115 / 136 | 6 / 9 |
| desktop_inspect Finder | 889 / 1036 | 377 / 398 |
| desktop_inspect Ghostty | 551 / 737 | 42 / 53 |
| desktop_windows, missing pid | 69 / 115 | 5 / 6 |

The outputs are the same size, except that an inspect is about 4.7 KB larger on native2. Its text is identical; the difference is the screenshot, about 3% larger at the same JPEG quality (70), because native2 scales with CoreGraphics and Node with `sips`.

### Intended differences

A model shouldn't care about any of these, but they make Node's tests and the parity files differ:

- The route is `local`, not `bridge`, and Peekaboo's `diagnostics` aren't sent.
- A paste into an app that isn't active first makes its window key, as Peekaboo does: a SkyLight activation record, then a window-routed click on blank title-bar chrome. A window with no blank chrome in its title row, such as Finder's with its toolbar, is refused before input, as on Node, with a hint to bring it forward. live-check #114 therefore focuses Finder first, which Node's foreground desktop_open did implicitly.
- A key refused because focus isn't in the window says refused, since nothing was sent; Node says unknown.
- desktop_wait reads the app's full inventory. Node's size-bounded apps list can report a running app as `app_not_listed`.
- An unknown but well-formed `ps1_` snapshot says the observation no longer belongs to the running desktop.
- Actions that list an app's windows leave out the untitled off-screen windows Node counts in `hidden_windows` while an app launches or changes, so steps-manage shows that count only on Node.
- KEY_SEQUENCE_STOPPED says the sequence stopped after N keys; Node adds that the next key may have been sent.
- desktop_launch and desktop_open run in the background unless `activate` is true, so an agent opening an app doesn't take the user's typing ([#162](https://github.com/githubnext/desktop-tools/issues/162)). Node always brings the app forward, and has no `activate`.

### Keeping the two in step

- CI builds native2, runs its tests, and runs `node scripts/contract.mjs --check`, so a tool whose description or schema changes in `src/` fails until native2's contract is regenerated. A change in behaviour that isn't ported still shows up only in the next parity run.
- `ContractText.swift` is compiled from the Node server's instructions and tools/list, run with `--wire 2`, so Node stays the source of truth until the switch. Text native2 owns sits in `src/tools.ts` behind `wire: 2` in `desktopTools` and `desktopToolRules`: desktop_launch and desktop_open's descriptions and `activate`, and the instructions' sentence on working in the background (#162). The shipped stack takes no fixes before the cutover, so wire 1 keeps the old text. Embedders on wire 2, such as ace's channel, pass `wire: 2` to both to offer the same text (#173).

### What must survive (ace)

[githubnext/ace](https://github.com/githubnext/ace) embeds this package. It uses:

- the C ABI, through `bun:ffi` in `apps/desktop/src/native.ts`;
- `createDesktop` from `@githubnext/desktop-tools`, in `apps/host/src/desktop.ts`;
- `@githubnext/desktop-tools/protocol` and `/tools`, in `packages/channel/src/desktop.ts`;
- `desktop-tools-client`, which `apps/desktop/scripts/helper.ts` copies as `ace-desktop-client`.

native2's dylib exports the same 17 C functions as `native/`, but the wire behind them is different, so `native/`'s `desktop-tools-client` can't talk to it. `createDesktop({ wire: 2 })` with native2's own `desktop-tools-client` can: it forwards each request whole as one tool call (`desktop_` plus its op). Through the same host, `dist/mcp.js --wire 2` matches native2's MCP server on every calls file. ace switches by changing that config and the client it copies.

## The road

Each step ships on its own and can be reverted.

1. **Keep it from rotting.** Done: CI builds and tests native2 and checks the contract. Port each tool change to native2 in the same PR, with its calls entries.
2. **Close the tool gaps** above. Run each fix through its calls and steps files.
3. **Finish the live checks** with the user's go-ahead, since they take over the pointer and the front app. Done: steps-pointer, steps-manage, the Dock step, and live-check #70, #77, #79, #81, #82, #86, #88, #89, #92, #99, #107, #110, #111 and #114 through `--server`, where Swift and Node now pass the same checks. Still to run: the Safari checks with Safari closed, and #162.
4. **Harden the runtime.** The socket lease (`<socket>.lock`, as Peekaboo's) and draining calls on stop are in. The dev app signs the dylib and client, and the peer check refuses an unsigned client. Still to do: sign the MCP binary once it's bundled (step 7), and run the approval prompt, pause and SELF_TARGET checks through the app.
5. **Bridge the wire.** Done: native2's `desktop-tools-client`, one-shot (`<client> <socket> <tool> [--verbose]`, arguments on stdin, one JSON line out) or serving (`<client> <socket> --serve`, one request line in and one reply line out per call, tagged by id, with `{"cancel": id}` passed to the host), opening its containing app in the background when no host serves; and `createDesktop({ wire: 2 })`, which keeps one serving client per config, restarts it when it exits, and holds the event loop only while a call waits ([#172](https://github.com/githubnext/desktop-tools/issues/172)). Against one release host, `desktop_windows` p50 is 13.0 ms through `dist/mcp.js --wire 2`, 10.8 ms through native2's MCP server, and 16.5 ms for a one-shot client. `createDesktop`, `/protocol`, `/tools`, `dist/mcp.js` and ace keep working against a native2 host by changing one option.
6. **Dogfood in the app.** The switch is in: `npm run dev-app -- --native2` bundles native2's dylib and client in place of `native/`'s, and native2's client answers `desktop-client status` and `repair` with `native/`'s output. The bundled dylib is 4.3 MB and the client 0.3 MB, against 40 MB and 43 MB for `native/`'s. In the dev app, with its own grants, `live-check` through `dist/mcp.js --wire 2` passes the same 26 checks as the standalone host, #114's Finder files paste included. Remaining: run the dev app daily with `DESKTOP_TOOLS_STATE=~/.local/state/desktop-tools-dev node dist/mcp.js --wire 2`.
7. **Ship the Swift MCP server.** Bundled: `npm run dev-app -- --native2` puts `desktop-tools-mcp` in the app, signed with the client's identifier, since the host admits exactly one. Run from the app, it serves the app's own socket (`DESKTOP_TOOLS_STATE`, or the app's state folder), opens the app in the background when nothing serves it, as the client does, and refuses with HOST_NOT_SERVING when a signed host drops it. Through it, the dev app passes the 26 live checks the standalone host does, #114 included. Still to do: point the README's setup at it. Keep `dist/mcp.js` as a shim that runs the bundled binary, so existing `npx` configs keep working. Release it, and cut a release that can switch back.
8. **Delete, after agreeing it with ace:** `native/vendor/Peekaboo`, `native/sources/client` and runtime, and the tool logic in `src/client.ts`, leaving a thin wrapper for the API ace imports. Make native2 the contract's source of truth, so `ContractText` stops being generated from Node. This step is the user's decision.

Steps 2 to 4 can run in parallel. Step 5 was the hinge: with it in, steps 6 to 8 don't break anyone.
