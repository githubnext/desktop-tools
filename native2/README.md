# native2: the Swift host and MCP server (#143)

The desktop tools' only native code: a Swift MCP server, host and embedding runtime with no Peekaboo and no Node. It replaced the Peekaboo stack (`native/`, the Node tool logic in `src/client.ts` and wire 1), which was removed after 0.18.0. Its tools were ported from what that stack sent and return the same results, field for field; the porting history and the parity runs are in this file's and `CUTOVER.md`'s Git history.

## Layout

| Module | What it holds |
|---|---|
| `DesktopProtocol` | JSON, wire framing, `ToolError`, and the contract: every tool's description, schema and action flag, the shared rules and the MCP server's instructions, declared in `ContractTools.swift` and read through `Contract`. `desktop-tools-mcp --contract` exports them, and `npm run contract` writes that into `src/contract.ts`, which embedders import as `/tools`; CI fails when it is stale. It is code, not a resource, because `Bundle.module` crashes in an embedded dylib |
| `DesktopCore` | Result bounding, window availability and the approved-callers store, with no macOS calls |
| `DesktopMac` | Everything that touches macOS: Accessibility reads (`Elements`, `AX`), capture, apps, windows, and input (`Pointer`, `Keyboard`, `Gestures`) |
| `DesktopPeer` | Who is at the other end of the socket, by the signature of its audit token's process (`Peer.swift`), and this process's own signing |
| `DesktopHost` | The tools, the snapshot store, the socket server, admission (`Admission.swift`: approved callers, pause, own-UI guard) and the runtime hooks |
| `desktop-tools-host` | A standalone host, run from a terminal for development; it uses the terminal's macOS grants |
| `desktop-tools-app` | The Desktop Tools menu bar app, which loads `libDesktopTools.dylib` |
| `desktop-tools-mcp` | The stdio MCP server, which forwards each call to the host |
| `desktop-tools-client` | One tool call per run, or every call over one connection with `--serve`, for `createDesktop` and `dist/mcp.js` with options (docs/node.md) |
| `DesktopTools` | `libDesktopTools.dylib`, the menu bar app's embedding runtime with the C ABI in docs/embed.md: it serves the host's `Server` and draws the agent cursor, window outline and activity list through `DesktopHost/Hooks.swift` |

The standalone host serves `~/.local/state/desktop-tools2/desktop.sock`, or `$DESKTOP_TOOLS2_STATE/desktop.sock`, so it runs beside the installed Desktop Tools, which serves `~/.local/state/desktop-tools`. It accepts a connection only from the same user, and, when the host is signed, only from an MCP binary signed by the same team with the expected identifier (`DesktopPeer/Peer.swift`: the socket's audit token, checked with Security and a CDHash read before and after). In turn, a signed client or MCP server sends nothing to a host that isn't the same user's and signed by its team (`DesktopAppLink/Trust.swift`).

## How an action runs

`Tools.act` in `DesktopHost/Action.swift` is the one runner for input on a snapshot. It looks the snapshot up, checks the element, runs the tool's `precheck`, spends the snapshot, runs `deliver` on its own thread, and then either returns the refusal or the fresh observation with the action merged in. `deliver` returns a `Delivery` (the fields of Peekaboo's `DesktopActionOutcome`, which it was ported from) or throws a `Refusal`, which sends nothing and returns the snapshot. Anything else thrown during delivery is reported as unknown.

A `ToolError` from an action tool's argument checks becomes a refused action; for other tools it is plain error text.

## Changing a tool

1. Change its description or schema in `Sources/DesktopProtocol/ContractTools.swift` (a tool that takes `expect` declares it in its schema; the host reads that), then `npm run contract` to regenerate `src/contract.ts` for embedders.
2. Change the macOS part in `DesktopMac` and the tool in `DesktopHost`, routed in `Tools.call`, with a test in `Tests` where it can run without the desktop.
3. Build, restart the host, and compare with the installed release:

```sh
swift build -c release --package-path native2
pkill -f native2/.build/release/desktop-tools-host; (nohup native2/.build/release/desktop-tools-host >/tmp/host2.log 2>&1 &)
node native2/scripts/parity.mjs calls native2/scripts/calls-core.json   # argument checks and refusals
node native2/scripts/parity.mjs steps native2/scripts/steps-core.json   # actions on the fixture window
```

`parity.mjs` runs each entry through two MCP servers, one at a time, and prints where they differ: `--server` (this checkout's release build by default) and `--baseline` (`node dist/mcp.js` by default, which hands over to the installed app's bundled server). `calls` sends each `[tool, args]` as is. `steps` inspects the fixture window first and fills in `"$snapshot"`, `"$pid"`, `"$window"`, `"$role:AXTextField"` and `"$label:Press me"`. Add each fix's calls and steps entries to the files. Run calls-text between `clip save` and `clip restore`, since it writes the clipboard. The steps files act on live windows; they and `node scripts/live-check.mjs --server native2/.build/release/desktop-tools-mcp` need an unlocked session.

The fixture is a small AppKit window that logs every mouse event it receives:

```sh
swiftc -O native2/fixture/main.swift -o native2/.build/fixture
(nohup native2/.build/fixture >/tmp/fixture.log 2>&1 &)
```

The cursor lab, `native2/fixture/cursorlab/run.sh`, is a playground for the agent cursor's motion (`DesktopTools/Cursor.swift`). Agents break out of your real pointer, click in three scene windows, then merge back into the pointer or fade. The lab window has switches and sliders for each principle and timing, a ¼× slow motion, and each input's wait for its cursor measured against `Hooks.pointerLimit`. Changes save to `~/.local/state/desktop-tools2/cursor-lab.json`, and `--send` starts a run at launch. Unlike the real cursor, the lab's overlay shows in captures and recordings.

Final results are compacted (#144) by `DesktopCore/Compact.swift`, a port of the removed `src/compact.ts`; CoreTests check it against that code's recorded output in `Tests/fixtures/compact`. Internal reads, such as notifications reading the Notification Center window, use `Tools.whole` and keep the full shape. `DESKTOP_TOOLS_VERBOSE=1` turns compaction off.

## Known gaps

- desktop_fill_password fills only inside the dylib, where the app's hook decides; the standalone host refuses, as a host with no hook should.
- desktop_menubar_items falls back, as Peekaboo did, to WindowServer's status item windows where MenuBarAgent doesn't draw the menu bar, and clicks such an item through its window. The fallback is unit-tested but not checked live.
- desktop_switch_space is checked only up to its refusals, on a Mac with one Space.
- A Save sheet on this macOS has no `PathTextField`, so desktop_dialog_answer can't read its folder back and a path answer ends unknown even when Go to Folder took it. The name is read back.
- A standalone Open panel (TextEdit's File > Open…) is an `AXStandardWindow`, which path entry and button presses don't treat as a dialog, so both refuse it; desktop_dialog still lists it.
- desktop_key refuses a window while a sheet holds its keyboard focus, so a stray sheet such as Go to Folder can only be closed with a foreground desktop_system_key.
- live-check's Safari checks (#79, #82, #86, #88, #92's web grid, #99's web field, #107's read) skip while the user's Safari is open.

## Speed

`node scripts/bench.mjs --runs 20` on 2026-10-20, read-only, p50 / p95 in milliseconds, the Peekaboo stack (`node dist/mcp.js` with the app installed then) against this server bundled in the dev app:

| | Peekaboo stack | native2 |
|---|---|---|
| startup | 110 | 20 |
| desktop_apps | 171 / 179 | 29 / 40 |
| desktop_windows | 115 / 136 | 6 / 9 |
| desktop_inspect Finder | 889 / 1036 | 377 / 398 |
| desktop_inspect Ghostty | 551 / 737 | 42 / 53 |

Argument checks and refusals answer in about 1 ms. `node native2/scripts/bench.mjs` times the core tools on the fixture through a build and the installed release.
