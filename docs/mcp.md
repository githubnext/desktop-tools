# Use from an MCP client

`desktop-tools-mcp` (`dist/mcp.js`) serves the desktop tools over stdio MCP, with Ace's native-first guidance as its instructions. By default it uses the [Desktop Tools app](app.md)'s signed client and socket in `~/.local/state/desktop-tools`. Run it from this repository with `npx`, pinned to a release tag, or from a checkout with `node`:

```sh
claude mcp add desktop -- npx -y --package=github:githubnext/desktop-tools#v0.13.1 desktop-tools-mcp
claude mcp add desktop -- node <path>/dist/mcp.js
```

The [README](https://github.com/githubnext/desktop-tools#set-up-for-an-agent) has the setup for Codex and for clients configured with JSON.

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
command = "npx"
args = ["-y", "--package=github:githubnext/desktop-tools#v0.13.1", "desktop-tools-mcp"]
```

The tool names, descriptions, and argument schemas come from `@githubnext/desktop-tools/tools` (`desktopTools`, `desktopRequest`), which Ace's `desktop_*` tools also use. [Tools](tools.md) lists them. The descriptions don't repeat the rules every tool shares: exact targets, single-use snapshots, background and foreground input, what each outcome means, pausing, `desktop_wait` and `expect`, and the recipes. `desktopToolRules(app)` returns those rules, and the server adds them to its instructions; a host with its own agent guidance should include them too.

The server names the agent in the host's window highlight from the MCP client's `clientInfo`: Claude, Codex, Cursor, Gemini or Copilot when the client name contains one, otherwise the client's `title`, otherwise "Agent".

Action results start with `Outcome: completed`, `refused`, or `unknown`. Actions run one at a time, and `notifications/cancelled` aborts a call; cancellation does not undo input already delivered.

**Warning:** the server acts with the host app's macOS Accessibility, Screen Recording, and clipboard permissions. The [Desktop Tools app](app.md#approved-agents) asks once per agent, such as Claude Code or a terminal, before serving it, and refuses it with `CALLER_NOT_APPROVED` until you choose Allow. It asks for no approval per call beyond that and what the MCP client itself requires, so any session of an allowed agent can read the screen and clipboard and send input to any app but Desktop Tools itself.
