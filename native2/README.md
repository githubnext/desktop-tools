# native2: the single-codebase Swift spike (#143)

A Swift MCP server and host with no Peekaboo and no Node. Each tool is ported from what the Node server and the native client send today, and returns the same result, field for field, so a model can't tell them apart except by speed.

## Layout

| Module | What it holds |
|---|---|
| `DesktopProtocol` | JSON, wire framing, `ToolError`, and the contract (`ContractText.swift`), which `node scripts/contract.mjs` compiles from the Node server's instructions and tools/list; `--check` fails when they differ. It is compiled in because `Bundle.module` crashes in an embedded dylib |
| `DesktopCore` | Result bounding, window availability and the approved-callers store, with no macOS calls |
| `DesktopMac` | Everything that touches macOS: Accessibility reads (`Elements`, `AX`), capture, apps, windows, and input (`Pointer`, `Keyboard`, `Gestures`) |
| `DesktopHost` | The tools, the snapshot store, the socket server, admission (`Admission.swift`: approved callers, pause, own-UI guard) and the runtime hooks |
| `desktop-tools-host` | The host, run from a terminal for now; it holds the macOS grants |
| `desktop-tools-mcp` | The stdio MCP server, which forwards each call to the host |
| `DesktopTools` | `libDesktopTools.dylib`, the menu bar app's embedding runtime with native/'s C ABI (docs/embed.md): it serves the host's `Server` and draws the agent cursor, window outline and activity list through `DesktopHost/Hooks.swift` |

The host serves `~/.local/state/desktop-tools2/desktop.sock`, or `$DESKTOP_TOOLS2_STATE/desktop.sock`, so it runs beside the installed Desktop Tools. It accepts a connection only from the same user, and, when the host is signed, only from an MCP binary signed by the same team with the expected identifier (`DesktopMac/Peer.swift`: the socket's audit token, checked with Security and a CDHash read before and after).

## How an action runs

`Tools.act` in `DesktopHost/Action.swift` is the one runner for input on a snapshot. It looks the snapshot up, checks the element, runs the tool's `precheck`, spends the snapshot, runs `deliver` on its own thread, and then either returns the refusal or the fresh observation with the action merged in. `deliver` returns a `Delivery` (Peekaboo's `DesktopActionOutcome` fields) or throws a `Refusal`, which sends nothing and returns the snapshot. Anything else thrown during delivery is reported as unknown.

A `ToolError` from an action tool's argument checks becomes a refused action, as in Node; for other tools it is plain error text.

## Porting a tool

1. Read what produces the result today: the tool's validation in `src/client.ts`, its handler in `src/` or `native/Sources/client/`, and the Peekaboo service it calls in `native/vendor/Peekaboo`. Copy messages, hints and codes exactly.
2. Add the macOS part to `DesktopMac` and the tool to `DesktopHost`, and route it in `Tools.call`.
3. Build, restart the host, and compare with Node:

```sh
swift build -c release --package-path native2
pkill -f native2/.build/release/desktop-tools-host; (nohup native2/.build/release/desktop-tools-host >/tmp/host2.log 2>&1 &)
node native2/scripts/parity.mjs calls native2/scripts/calls-core.json   # argument checks and refusals
node native2/scripts/parity.mjs steps native2/scripts/steps-core.json   # actions on the fixture window
```

`calls` sends each `[tool, args]` as is. `steps` inspects the fixture window first and fills in `"$snapshot"`, `"$pid"`, `"$window"`, `"$role:AXTextField"` and `"$label:Press me"`. The Node side is `node dist/mcp.js`, which talks to the installed Desktop Tools app.

The fixture is a small AppKit window that logs every mouse event it receives:

```sh
swiftc -O native2/fixture/main.swift -o native2/.build/fixture
(nohup native2/.build/fixture >/tmp/fixture.log 2>&1 &)
```

Differences that are intended: the route is `local`, not `bridge`, since there is no bridge; Peekaboo's `diagnostics` aren't sent; and a key refused because focus isn't in the window says refused, since nothing was sent, where Node says unknown.

## Status

All 48 tools in the contract run in the Swift host. Every calls file agrees with Node entry for entry:

| File | Entries |
|---|---|
| calls-core | 62 |
| calls-inspect | 25 |
| calls-keys | 15 |
| calls-manage | 165 |
| calls-menus | 96 |
| calls-pointer | 39 |
| calls-spaces | 9 |
| calls-system | 47 |
| calls-text | 106 |
| calls-wait | 19 |

Run calls-text between `clip save` and `clip restore`, since it writes the clipboard. The steps files act on live windows; they and `node scripts/live-check.mjs --server native2/.build/release/desktop-tools-mcp` need an unlocked session.

Final results are compacted as Node's are (#144), by a port of `src/compact.ts` that CoreTests check against `dist/compact.js` on `test/fixtures/compact`. Internal reads, such as notifications reading the Notification Center window, use `Tools.whole` and keep the full shape. `DESKTOP_TOOLS_VERBOSE=1` turns compaction off.

The steps files that stay in the background, run on an unlocked session:

| File | Same as Node |
|---|---|
| steps-core | 18 of 18 |
| steps-menus | 15 of 15 |
| steps-dialogs, without its Dock step | 7 of 7 |
| steps-text, without fill_password | 43 of 45 |
| steps-inspect, steps-system | all but environmental diffs |

The two steps-text diffs are reads of a field both runs insert into, one after the other. steps-inspect and steps-system differ only where the desktop changed between the runs (Node's 8 s OCR timeout, a terminal's title spinner, a transient window). steps-pointer, steps-manage and the Dock step move the real pointer or bring apps forward, so they haven't been run live. live-check's clipboard and system-state checks (#96, #83) pass; its other checks open TextEdit, Finder and browser windows.

More intended differences, beyond the route and diagnostics above:

- desktop_wait reads the app's full inventory, where Node's size-bounded apps list reports a running app as `app_not_listed`.
- An unknown but well-formed `ps1_` snapshot says the observation no longer belongs to the running desktop.

Known gaps:

- desktop_fill_password fills only inside the dylib, where the app's hook decides; the standalone host refuses, as a host with no hook should.
- desktop_set_cell can't edit Finder's cells (CELL_NOT_EDITABLE), and the clipboard isn't reserved across calls.
- desktop_dialog_answer doesn't type a path into an Open or Save panel, and desktop_menubar_items has no fallback when MenuBarAgent doesn't draw the menu bar.
- desktop_switch_space is checked only up to its refusals, on a Mac with one Space.
- The runtime dylib has no socket lease, its stop doesn't drain calls in flight, and it has been run only unsigned.

## Speed

`node native2/scripts/bench.mjs` times the core tools on the fixture through both servers. p50/p90 in milliseconds, at the go/no-go bench:

| Tool | Node | Swift |
|---|---|---|
| apps | 263/307 | 31/39 |
| windows | 198/238 | 20/23 |
| inspect | 464/541 | 47/51 |
| click | 784/1119 | 148/151 |
| type | 693/3282 | 60/87 |

Argument checks and refusals answer in about 1 ms, against about 100 ms through Node.
