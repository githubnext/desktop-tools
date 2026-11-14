# Use from an MCP client

The [Desktop Tools app](app.md) bundles the MCP server, `Desktop Tools.app/Contents/MacOS/desktop-tools-mcp`, written in Swift. It serves the desktop tools over stdio MCP, with Ace's native-first guidance as its instructions, and needs no Node. Set it up by its path:

```sh
claude mcp add desktop -- "/Applications/Desktop Tools.app/Contents/MacOS/desktop-tools-mcp"
```

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.desktop]
command = "/Applications/Desktop Tools.app/Contents/MacOS/desktop-tools-mcp"
```

The [README](https://github.com/githubnext/desktop-tools#set-up-for-an-agent) has the setup for clients configured with JSON.

The server serves the socket in its app's state folder (`DESKTOP_TOOLS_STATE`, else the folder its bundle ID chooses), or `--socket <path>`, and names its app in the instructions and rules: the app it ships in, or `--name <app>`. So the [development app](build.md#development-app)'s server, `Desktop Tools Dev.app/Contents/MacOS/desktop-tools-mcp`, serves `~/.local/state/desktop-tools-dev` as **Desktop Tools Dev** with no options.

## Another app's grants

A signed host serves only its own app's programs, so an app that embeds Desktop Tools, such as Ace, serves MCP only through its own `desktop-tools-mcp`. To offer that, **bundle `desktop-tools-mcp` from the same native build beside the app's `desktop-tools-client`, signed with the client's identifier**, as [Embed](embed.md) describes. Then set the MCP server up as that file, with `--socket` for the socket the app serves:

```sh
claude mcp add desktop -- "/Applications/Example.app/Contents/MacOS/desktop-tools-mcp" --socket ~/.local/state/example/desktop.sock
```

It names its app (its `CFBundleName`) in the instructions and rules; `--name` overrides that. Without a bundled server, an `npx` setup that passes `--client` for that app exits with a message saying to bundle one.

## npx setups

`npx -y --package=github:githubnext/desktop-tools#v0.20.0 desktop-tools-mcp` (Node 22 or later) also works. It runs only a launcher, `dist/mcp.js`, which finds the app's server beside the client the app links in its state folder and hands stdin and stdout over to it; no MCP traffic passes through Node. `--client <App>.app/Contents/MacOS/desktop-tools-client` runs that app's server instead, and `--socket` and `--name` are passed on to it. `--wire 2` is accepted and ignored, and `--wire 1`, the removed Peekaboo stack, is refused.

When there is no server to hand over to, the launcher exits with a message instead: no app has linked its client, the app is from before 0.17.0 and has no server of its own (the message names its version and the release to install), or `--client` names an embedder's app that ships no `desktop-tools-mcp` (bundle one, as [above](#another-apps-grants)). Updating the `npx` tag doesn't update the app, which holds the macOS permissions. A setup pinned before v0.17.0 is refused with `CLIENT_OUTDATED`, so update its tag, or better, point it at the app's server.

The tool names, descriptions, and argument schemas are declared in Swift (`native2/Sources/DesktopProtocol/ContractTools.swift`), and `@githubnext/desktop-tools/tools` (`desktopTools`, `desktopRequest`) exports them, generated from that file, for Ace's `desktop_*` tools and other embedders. [Tools](tools.md) lists them. The descriptions don't repeat the rules every tool shares: exact targets, single-use snapshots, background and foreground input, what each outcome means, pausing, `desktop_wait` and `expect`, and the recipes. `desktopToolRules(app)` returns those rules, and the server adds them to its instructions; a host with its own agent guidance should include them too.

The server names the agent in the host's window highlight from the MCP client's `clientInfo`: Claude, Codex, Cursor, Gemini or Copilot when the client name contains one, otherwise the client's `title`, otherwise "Agent".

Action results start with `Outcome: completed`, `refused`, or `unknown`. Actions run one at a time, and `notifications/cancelled` aborts a call; cancellation does not undo input already delivered.

**Warning:** the server acts with the host app's macOS Accessibility, Screen Recording, and clipboard permissions. The [Desktop Tools app](app.md#approved-agents) asks once per agent, such as Claude Code or a terminal, before serving it, and refuses it with `CALLER_NOT_APPROVED` until you choose Allow. It asks for no approval per call beyond that and what the MCP client itself requires, so any session of an allowed agent can read the screen and clipboard and send input to any app but Desktop Tools itself.
