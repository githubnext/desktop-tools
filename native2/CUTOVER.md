# Swapping over to native2 (#143)

native2 is merged beside the shipped stack, not in place of it. This page lists what still separates the two and the steps that would let native2 replace the Node server, the native client and Peekaboo. The [README](README.md) covers how native2 is built and checked.

## Today: side by side

| | Shipped | native2 |
|---|---|---|
| MCP server | `dist/mcp.js` (Node), set up through `npx` | `desktop-tools-mcp` (Swift, stdio), or `dist/mcp.js --wire 2` |
| Embedders | `createDesktop` | `createDesktop({ wire: 2 })`, with native2's `desktop-tools-client` |
| Per call | Node validates, then runs `desktop-tools-client` once per call | one long-lived socket to the host |
| Host | `Desktop Tools.app`, loading `libDesktopTools.dylib` (Peekaboo's Bridge) | `desktop-tools-host` from a terminal, or native2's `libDesktopTools.dylib` |
| Socket and state | `~/.local/state/desktop-tools` | `~/.local/state/desktop-tools2`, or `$DESKTOP_TOOLS2_STATE` |
| Wire | Peekaboo Bridge requests | length-prefixed JSON frames (`DesktopProtocol/Wire.swift`) |

They share no socket, state folder, lock or hotkey. native2 takes none of Peekaboo's `~/.peekaboo` locks, and neither the npm package (`files`), CI nor the release builds it. Every parity run so far drove both at once. The macOS grants differ: the standalone host uses the grants of the terminal that runs it, while the app holds its own.

## Issues

### Tools that don't do everything yet

- **desktop_fill_password** fills only inside the dylib, where the app's hook decides. The standalone host refuses.
- **desktop_set_cell** can't edit Finder's cells (it returns CELL_NOT_EDITABLE), and the clipboard isn't reserved across calls.
- **desktop_dialog_answer** doesn't type a path into an Open or Save panel.
- **desktop_menubar_items** has no fallback when MenuBarAgent doesn't draw the menu bar.
- **desktop_switch_space** is checked only up to its refusals, on a Mac with one Space.

### Runtime dylib

- It has no socket lease.
- `desktop_tools_stop` doesn't drain calls in flight.
- It has been run only unsigned. Nothing has exercised the signed peer check (same team, expected identifier, CDHash read before and after) or the app's approval prompt end to end.

### Not yet checked live

- steps-pointer, steps-manage and steps-dialogs' Dock step haven't run live: they move the real pointer or bring apps forward.
- Of live-check, only #96 and #83 have run through `--server`. The rest opens TextEdit, Finder, Safari and Chrome, switches input sources (#90), presses Command-Space (#89), or needs the app's approval prompt (#120).
- The bench has run only on the fixture.
- Background launch and open ([#162](https://github.com/githubnext/desktop-tools/issues/162)) haven't run live. The check: type continuously in TextEdit while launching an app that isn't running and opening a PDF in Preview, both without `activate`. No keystroke should land elsewhere and TextEdit should stay frontmost; then inspect and click the new windows in the background. It needs the user's go-ahead, since a regression takes their focus.

### Intended differences

A model shouldn't care about any of these, but they make Node's tests and the parity files differ:

- The route is `local`, not `bridge`, and Peekaboo's `diagnostics` aren't sent.
- A key refused because focus isn't in the window says refused, since nothing was sent; Node says unknown.
- desktop_wait reads the app's full inventory. Node's size-bounded apps list can report a running app as `app_not_listed`.
- An unknown but well-formed `ps1_` snapshot says the observation no longer belongs to the running desktop.
- desktop_launch and desktop_open run in the background unless `activate` is true, so an agent opening an app doesn't take the user's typing ([#162](https://github.com/githubnext/desktop-tools/issues/162)). Node always brings the app forward, and has no `activate`.

### Keeping the two in step

- CI builds native2, runs its tests, and runs `node scripts/contract.mjs --check`, so a tool whose description or schema changes in `src/` fails until native2's contract is regenerated. A change in behaviour that isn't ported still shows up only in the next parity run.
- `ContractText.swift` is compiled from the Node server's instructions and tools/list, so Node stays the source of truth until the switch. The exception is text native2 owns, written in `scripts/contract.mjs` over Node's: desktop_launch and desktop_open's descriptions and `activate`, and the instructions' sentence on working in the background (#162). The shipped stack takes no fixes before the cutover, so these change in native2 only. The script stops if the Node text they replace changes.

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
3. **Finish the live checks** with the user's go-ahead, since they take over the pointer and the front app: steps-pointer, steps-manage, the Dock step and the full `live-check --server`, then the bench on real apps.
4. **Harden the runtime:** add the socket lease, drain calls in flight on stop, then sign the dylib, client and MCP binary with the team identity. Run the approval prompt, pause and SELF_TARGET checks through the app.
5. **Bridge the wire.** Done: native2's one-shot `desktop-tools-client` (`<client> <socket> <tool> [--verbose]`, arguments on stdin, one JSON line out, opening its containing app in the background when no host serves) and `createDesktop({ wire: 2 })`. `createDesktop`, `/protocol`, `/tools`, `dist/mcp.js` and ace keep working against a native2 host by changing one option.
6. **Dogfood in the app.** Add a build switch so `npm run dev-app` bundles native2's dylib and client instead of `native/`'s, and run the dev app daily with the MCP server on `--wire 2`.
7. **Ship the Swift MCP server.** Bundle and sign `desktop-tools-mcp` in the app, and point the README's setup at it. Keep `dist/mcp.js` as a shim that runs the bundled binary, so existing `npx` configs keep working. Release it, and cut a release that can switch back.
8. **Delete, after agreeing it with ace:** `native/vendor/Peekaboo`, `native/sources/client` and runtime, and the tool logic in `src/client.ts`, leaving a thin wrapper for the API ace imports. Make native2 the contract's source of truth, so `ContractText` stops being generated from Node. This step is the user's decision.

Steps 2 to 4 can run in parallel. Step 5 was the hinge: with it in, steps 6 to 8 don't break anyone.
