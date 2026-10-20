# Swapping over to native2 (#143)

native2 is merged beside the shipped stack, not in place of it. This page lists what still separates the two and the steps that would let native2 replace the Node server, the native client and Peekaboo. The [README](README.md) covers how native2 is built and checked.

## Today: side by side

| | Shipped | native2 |
|---|---|---|
| MCP server | `dist/mcp.js` (Node), set up through `npx` | `desktop-tools-mcp` (Swift, stdio) |
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

### Intended differences

A model shouldn't care about any of these, but they make Node's tests and the parity files differ:

- The route is `local`, not `bridge`, and Peekaboo's `diagnostics` aren't sent.
- A key refused because focus isn't in the window says refused, since nothing was sent; Node says unknown.
- desktop_wait reads the app's full inventory. Node's size-bounded apps list can report a running app as `app_not_listed`.
- An unknown but well-formed `ps1_` snapshot says the observation no longer belongs to the running desktop.

### Keeping the two in step

- Nothing in CI builds native2, runs its tests, or runs `node scripts/contract.mjs --check`. A change to a tool in `src/` or `native/` that isn't ported will go unnoticed until the next parity run.
- `ContractText.swift` is compiled from the Node server's instructions and tools/list, so Node stays the source of truth until the switch.

### What must survive (ace)

[githubnext/ace](https://github.com/githubnext/ace) embeds this package. It uses:

- the C ABI, through `bun:ffi` in `apps/desktop/src/native.ts`;
- `createDesktop` from `@githubnext/desktop-tools`, in `apps/host/src/desktop.ts`;
- `@githubnext/desktop-tools/protocol` and `/tools`, in `packages/channel/src/desktop.ts`;
- `desktop-tools-client`, which `apps/desktop/scripts/helper.ts` copies as `ace-desktop-client`.

native2's dylib exports the same 17 C functions as `native/`. The wire behind them is different, though, so today's `desktop-tools-client` and `createDesktop` can't talk to it. This is the main blocker. Dropping native2's dylib into the app breaks both the Node MCP server and ace.

## The road

Each step ships on its own and can be reverted.

1. **Keep it from rotting.** Add a CI job that builds native2, runs CoreTests and runs `contract.mjs --check`. Port each tool change to native2 in the same PR, with its calls entries.
2. **Close the tool gaps** above. Run each fix through its calls and steps files.
3. **Finish the live checks** with the user's go-ahead, since they take over the pointer and the front app: steps-pointer, steps-manage, the Dock step and the full `live-check --server`, then the bench on real apps.
4. **Harden the runtime:** add the socket lease, drain calls in flight on stop, then sign the dylib, client and MCP binary with the team identity. Run the approval prompt, pause and SELF_TARGET checks through the app.
5. **Bridge the wire.** Build a native2 `desktop-tools-client` with today's contract: `<client> <socket> <args…>`, input on stdin, JSON out, the same refusal codes and exit behaviour. It speaks native2's wire instead. `createDesktop`, `/protocol`, `/tools`, `dist/mcp.js` and ace then keep working unchanged against a native2 host. A `createDesktop` that speaks the wire directly could replace it later, behind the same API.
6. **Dogfood in the app.** Add a build switch so `npm run dev-app` bundles native2's dylib and client instead of `native/`'s, and run the dev app daily.
7. **Ship the Swift MCP server.** Bundle and sign `desktop-tools-mcp` in the app, and point the README's setup at it. Keep `dist/mcp.js` as a shim that runs the bundled binary, so existing `npx` configs keep working. Release it, and cut a release that can switch back.
8. **Delete, after agreeing it with ace:** `native/vendor/Peekaboo`, `native/sources/client` and runtime, and the tool logic in `src/client.ts`, leaving a thin wrapper for the API ace imports. Make native2 the contract's source of truth, so `ContractText` stops being generated from Node. This step is the user's decision.

Steps 1 to 4 can run in parallel. Step 5 is the hinge: once it lands, steps 6 to 8 don't break anyone.
