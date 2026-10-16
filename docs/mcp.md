# Use from an MCP client

`desktop-tools-mcp` (`dist/mcp.js`) serves the desktop tools over stdio MCP, with Ace's native-first guidance as its instructions. By default it uses the [Desktop Tools app](app.md)'s signed client and socket in `~/.local/state/desktop-tools`:

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
