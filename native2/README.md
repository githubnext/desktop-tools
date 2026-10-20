# native2: the single-codebase Swift spike (#143)

A Swift MCP server and host with no Peekaboo and no Node. Each tool is ported from what the Node server and the native client send today, and returns the same result, field for field, so a model can't tell them apart except by speed.

## Layout

| Module | What it holds |
|---|---|
| `DesktopProtocol` | JSON, wire framing, `ToolError`, and the frozen contract (`contract/tools.json`, `contract/instructions.txt`) |
| `DesktopCore` | Result bounding and window availability, with no macOS calls |
| `DesktopMac` | Everything that touches macOS: Accessibility reads (`Elements`, `AX`), capture, apps, windows, and input (`Pointer`, `Keyboard`, `Gestures`) |
| `DesktopHost` | The tools, the snapshot store and the socket server |
| `desktop-tools-host` | The host, run from a terminal for now; it holds the macOS grants |
| `desktop-tools-mcp` | The stdio MCP server, which forwards each call to the host |

The host serves `~/.local/state/desktop-tools2/desktop.sock`, or `$DESKTOP_TOOLS2_STATE/desktop.sock`, so it runs beside the installed Desktop Tools.

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

## Speed

`node native2/scripts/bench.mjs` times the core tools on the fixture through both servers.
